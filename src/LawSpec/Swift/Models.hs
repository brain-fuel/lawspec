-- | Stateful models in Swift: each machine's portable spec, its callbacks to
-- the checked entries, and a Swift Testing test for each check (sequential,
-- parallel, each scenario, and supervision). The runtime's model runner
-- supplies generation and shrinking, the same on every target.
-- ref:DEC-stateful-models-linearizability ref:DEC-portable-seeded-generation
module LawSpec.Swift.Models (emitModels) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamModelChecks as Checks
import LawSpec.MachineSpec (machineSpec, scenarioWire)
import LawSpec.Common (Artifact(..))
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader, unitSourceFile)
import LawSpec.Swift.Names
import LawSpec.Swift.Entries
import qualified LawSpec.Swift.Effects as Effects
import qualified LawSpec.Swift.Policy as Policy
import Control.Monad (forM, unless)
import Data.List (nub, intercalate)

emitModels :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitModels layout bits datas units = concat <$> mapM unitFile
  [u | u <- units, not (null (C.unitMachines u) && null (C.unitSupervisors u))]
  where
    declarations = [(C.declarationId d, d) | u <- units, d <- C.unitDeclarations u]
    declaration identity = maybe (Left ("missing Swift model declaration " ++ C.idText identity)) Right (lookup identity declarations)
    callback identity = do
      d <- declaration identity
      e <- maybe (Left ("missing Swift model callback " ++ C.idText identity)) Right (lookup identity (entries units))
      let count = length (fst (C.functionType (C.declarationType d)))
      pure (Lambda [("context", Ty "Model.CallbackContext"), ("arguments", tValues)] tValue
        (Call (entryOwner e ++ "." ++ entryName e) (map Raw (["context.0", "context.1"] ++ ["arguments[" ++ show i ++ "]" | i <- [0 .. count - 1]]))))
    optional = maybe (pure (Raw "nil")) callback
    unitFile unit = do
      let names = Checks.machineNames unit
          parallel = maybe False C.harnessParallel (C.unitHarnessSettings unit)
      prepared <- forM (zip names (C.unitMachines unit)) $ \(name, machine) -> do
        unless (machineConsistency machine /= Eventual || machineAbstractRun machine /= Nothing)
          (Left ("Swift eventual model " ++ machineName machine ++ " needs abstract to compare the final state"))
        spec <- machineSpec bits datas (C.unitDeclarations unit) (C.unitContracts unit) machine
        start <- case machineStart machine of
          Just s -> (\a b -> TupleOf [a, b]) <$> callback (startRun s) <*> callback (startModel s)
          Nothing -> Left "a Swift model needs a start command"
        commands <- forM (machineCommands machine) $ \c -> do
          run <- callback (commandRun c)
          reference <- callback (commandReference c)
          condition <- optional (commandWhen c)
          pure (TupleOf [run, reference, condition])
        abstract <- optional (machineAbstractRun machine)
        let invariant (OnModel f) = f
            invariant (OnState f) = f
        invariants <- mapM (callback . invariant) (machineInvariants machine)
        ds <- mapM declaration (nub (foldr (:) [] machine))
        made <- Effects.factories units (Var "symbols") [(a, C.ProductionHandler) | a <- nub (concatMap Effects.uses ds)]
        let factoryTy = Ty "[(String, (Schema) throws -> Effects.Handler)]"
            factoriesName = name ++ "Factories"
            context = Pure "Model.contextWith" [Raw "LawSpec.Program.schema", Var factoriesName]
            -- A program with workflow policies runs its models on the
            -- workflow test runtime, as its laws do.
            withRuntime = if Policy.usesPolicies units
              then Lambda [("body", Ty "(Model.CallbackContext) throws -> Any")] (Ty "Any")
                (Call "Workflow.withTestRuntime" [Lambda [] (Ty "Any") (Invoke context [Var "body"])])
              else context
            created = Call "Model.create" [LongStr spec, start, ListOf (Ty "") commands, abstract, ListOf (Ty "") invariants]
            withContext = Pure "Model.withContext" [withRuntime, created]
            -- An actor model runs its system on the actor runtime.
            whole = if machineActor machine then Pure "Model.withActors" [Raw "ActorHost.host", withContext] else withContext
        pure (signature ("private func " ++ factoriesName) ["_ symbols: SymbolContext"] " throws -> [(String, (Schema) throws -> Effects.Handler)]"
          (renderBody factoryTy made) <> D.hardline <> D.hardline <>
          D.text ("/// The model " ++ machineName machine ++ ".") <> D.hardline <>
          signature ("private func " ++ name) [] " throws -> Model.Machine" (renderBody (Ty "Model.Machine") whole))
      cases <- forM (Checks.checks unit) $ \check -> do
        action <- case Checks.checkAction check of
          Checks.Sequential name _ -> pure (Call "Model.check" [Call name []])
          Checks.Parallel name _ -> pure (Call "ModelParallel.check" [Call name []])
          Checks.Scenario name _ program -> do
            wire <- scenarioWire bits datas (concatMap C.unitSessions units) program
            let text = P.programSpec (program { P.programWire = wire })
            pure (Call "Scenario.check" [Call name [], LongStr text])
          Checks.Supervision -> pure (Call "Supervision.check" [])
        pure (callDoc "@Test" [D.text (stringLiteral (Checks.checkLabel check))] <> D.hardline <>
          D.text ("func " ++ Checks.checkName check ++ "() async throws") <> blockDoc (
            D.text "try await LawThread.run" <> blockDoc (renderStatements (Statement action))))
      let suite = testName (C.unitId unit) ++ "Models"
          suiteDoc = D.text ("/// The models of " ++ C.idText (C.unitId unit) ++ ".") <> D.hardline <>
            D.text ("@Suite(" ++ stringLiteral (C.idText (C.unitId unit) ++ " models") ++ ") struct " ++ suite ++ " {") <>
            D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) cases) <> D.hardline <> D.text "}"
          doc = fileHeader (generatedHeader (unitSourceFile unit)) [["import LawSpecRuntime", "import LawSpecTesting", "import Testing"], ["@testable import " ++ moduleName]] <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) prepared <> (if null prepared then mempty else D.hardline <> D.hardline) <>
            (if parallel then suiteDoc else D.text "extension LawSpecTests {" <> D.nest 2 (D.hardline <> suiteDoc) <> D.hardline <> D.text "}") <>
            D.hardline
      pure [Artifact ("tests/LawSpec/" ++ suite ++ ".swift") (D.render layout doc) "generated" "test"]
