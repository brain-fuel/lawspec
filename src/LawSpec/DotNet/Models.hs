-- | Stateful models on .NET: each machine's portable spec, its callbacks to
-- the checked entries, and an xUnit test for each check (sequential,
-- parallel, each scenario, and supervision). The runtime's model runner
-- supplies generation and shrinking, the same on every target.
-- ref:DEC-stateful-models-linearizability ref:DEC-portable-seeded-generation
module LawSpec.DotNet.Models (emitModels) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamModelChecks as Checks
import LawSpec.MachineSpec (machineSpec, scenarioWire)
import LawSpec.Common (Artifact(..))
import LawSpec.DotNet.Code
import LawSpec.DotNet.Names
import LawSpec.DotNet.Entries
import qualified LawSpec.DotNet.Effects as Effects
import qualified LawSpec.DotNet.Policy as Policy
import Control.Monad (forM, unless)
import Data.List (nub, intercalate)

emitModels :: Lang -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitModels FSharp layout bits datas units = concat <$> mapM unitFile
  [u | u <- units, not (null (C.unitMachines u) && null (C.unitSupervisors u))]
  where
    declarations = [(C.declarationId d, d) | u <- units, d <- C.unitDeclarations u]
    declaration identity = maybe (Left ("missing .NET model declaration " ++ C.idText identity)) Right (lookup identity declarations)
    callback identity = do
      d <- declaration identity
      e <- maybe (Left ("missing .NET model callback " ++ C.idText identity)) Right (lookup identity (entries units))
      let count = length (fst (C.functionType (C.declarationType d)))
      pure ("(fun (context: Model.CallbackContext) (arguments: Value list) -> " ++ entryModule e ++ "." ++ entryFs e ++
        " (fst context) (snd context)" ++ concat [" (Runtime.item " ++ show i ++ " arguments)" | i <- [0 .. count - 1]] ++ ")")
    optional = maybe (pure "None") (fmap (\c -> "(Some " ++ c ++ ")") . callback)
    unitFile unit = do
      let names = Checks.machineNames unit
      prepared <- forM (zip names (C.unitMachines unit)) $ \(name, machine) -> do
        unless (machineConsistency machine /= Eventual || machineAbstractRun machine /= Nothing)
          (Left (".NET eventual model " ++ machineName machine ++ " needs abstract to compare the final state"))
        spec <- machineSpec bits datas (C.unitDeclarations unit) (C.unitContracts unit) machine
        start <- case machineStart machine of
          Just s -> (\a b -> "(" ++ a ++ ", " ++ b ++ ")") <$> callback (startRun s) <*> callback (startModel s)
          Nothing -> Left "a .NET model needs a start command"
        commands <- forM (machineCommands machine) $ \c -> do
          run <- callback (commandRun c)
          reference <- callback (commandReference c)
          condition <- optional (commandWhen c)
          pure ("(" ++ run ++ ", " ++ reference ++ ", " ++ condition ++ ")")
        abstract <- optional (machineAbstractRun machine)
        let invariant (OnModel f) = f
            invariant (OnState f) = f
        invariants <- mapM (callback . invariant) (machineInvariants machine)
        ds <- mapM declaration (nub (foldr (:) [] machine))
        made <- Effects.factories units (Var "symbols") [(a, C.ProductionHandler) | a <- nub (concatMap Effects.uses ds)]
        let factoryTy = Ty "(string * (Schema.Schema -> Effects.Handler)) list" "FSharpList<Tuple<string, FSharpFunc<Schema.Schema, Effects.Handler>>>"
            factoriesName = name ++ "Factories"
            factoriesDoc = D.text ("let private " ++ factoriesName ++ " : Scalar.SymbolContext -> " ++ tyText FSharp factoryTy ++ " =") <>
              D.nest 4 (D.hardline <> renderBody FSharp (tFun [tSymbols] factoryTy) (Lambda [("symbols", tSymbols)] factoryTy made))
            context = "Model.contextWith LawSpec.Generated.Program.schema " ++ factoriesName
            withRuntime = if Policy.usesPolicies units
              then "(fun body -> Workflow.withTestRuntime (fun () -> (" ++ context ++ ") body))"
              else "(" ++ context ++ ")"
        pure (factoriesDoc <> D.hardline <> D.hardline <> D.text ("/// The model " ++ machineName machine ++ ".") <> D.hardline <>
          D.text ("let private " ++ name ++ " () : Model.Model =") <> D.nest 4 (D.hardline <>
            D.text ("Model.create " ++ stringLiteral FSharp spec) <> D.nest 4 (D.hardline <>
              D.text start <> D.hardline <>
              D.text "[ " <> D.joinWith (D.hardline <> D.text "  ") (map D.text commands) <> D.text " ]" <> D.hardline <>
              D.text abstract <> D.hardline <>
              D.text ("[ " ++ intercalate "; " invariants ++ " ]")) <> D.hardline <>
            D.text ("|> Model.withContextFactory " ++ withRuntime) <>
            (if machineActor machine then D.hardline <> D.text "|> Model.withActors ActorHost.host" else mempty)))
      cases <- forM (Checks.checks unit) $ \check -> do
        action <- case Checks.checkAction check of
          Checks.Sequential name _ -> pure ("Model.check (" ++ name ++ " ())")
          Checks.Parallel name _ -> pure ("ModelParallel.check (" ++ name ++ " ())")
          Checks.Scenario name _ program -> do
            wire <- scenarioWire bits datas (concatMap C.unitSessions units) program
            pure ("Scenario.check (" ++ name ++ " ()) " ++ stringLiteral FSharp (P.programSpec (program { P.programWire = wire })))
          Checks.Supervision -> pure "Supervision.check ()"
        pure (D.text ("[<Fact(DisplayName = " ++ stringLiteral FSharp (Checks.checkLabel check) ++ ")>]") <> D.hardline <>
          D.text ("let " ++ Checks.checkName check ++ " () : unit =") <> D.nest 4 (D.hardline <> D.text action))
      let moduleName = testModule (C.unitId unit) ++ "Models"
          doc = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text ("/// The models of " ++ C.idText (C.unitId unit) ++ ".") <> D.hardline <>
            D.text "[<Xunit.Collection(\"LawSpec\")>]" <> D.hardline <>
            D.text ("module " ++ moduleName) <> D.hardline <> D.hardline <>
            D.text "open Xunit" <> D.hardline <> D.text "open LawSpec.Runtime" <> D.hardline <>
            D.text "open LawSpec.Testing" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) (prepared ++ cases) <> D.hardline
      pure [Artifact ("tests/LawSpec/" ++ last (splitDots moduleName) ++ ".fs") (D.render layout doc) "generated" "test"]
emitModels CSharp _ _ _ units
  | all (\u -> null (C.unitMachines u) && null (C.unitSupervisors u)) units = pure []
  | otherwise = Left "C# models are not emitted yet"
