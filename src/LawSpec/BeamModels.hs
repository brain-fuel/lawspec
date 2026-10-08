-- | Model evidence calls checked Core bridges in fresh ability/workflow
-- scopes. The portable runner supplies actual generation and shrinking;
-- EUnit, ExUnit and Gleeunit own the generated test entries.
-- ref:DEC-stateful-models-linearizability ref:DEC-typed-core-boundary
module LawSpec.BeamModels (emit) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import LawSpec.MachineSpec (machineSpec, scenarioWire)
import LawSpec.Common (Artifact(..))
import LawSpec.TestNames (unitTestNames)
import Control.Monad (forM, unless)
import Data.List (nub)

emit :: String -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target layout bits datas units = concat <$> mapM unitFiles
  [u | u <- units, not (null (C.unitMachines u) && null (C.unitSupervisors u))]
  where
    entries = Definitions.entries units
    declarations = [(C.declarationId d,d) | u <- units, d <- C.unitDeclarations u]
    declaration identity = maybe (Left ("missing BEAM model declaration " ++ C.idText identity)) Right (lookup identity declarations)
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    callback identity = do
      d <- declaration identity
      name <- maybe (Left ("missing checked BEAM model callback " ++ C.idText identity)) Right (lookup identity entries)
      let arguments = [D.text ("_LsArgument" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType (C.declarationType d)))]
      pure (E.lambda [E.tuple [schema,symbols],E.array arguments]
        (E.remote "lawspec_definitions" name (schema:symbols:arguments)))
    optional = maybe (pure (E.atom "none")) callback
    hasPolicies = any ((/= Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units)
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    caseFunctions cases =
      [E.function entry [] [action,E.atom (if target == "gleam" then "nil" else "ok")]
        | (entry,_,action) <- cases] ++
      [E.function (entry ++ "_test_") [] [E.tuple [E.atom "timeout",D.text "60",
        E.tuple [E.string title,E.lambda [] (E.call entry [])]]] | (entry,title,_) <- cases, target == "erlang"]
    unitFiles unit = do
      let moduleName = Definitions.adapterModule unit ++ "_lawspec_models"
          names = map (("model_" ++) . drop 4) (unitTestNames target (map machineName (C.unitMachines unit)))
      prepared <- forM (zip names (C.unitMachines unit)) $ \(name,machine) -> do
        unless (machineConsistency machine /= Eventual || machineAbstractRun machine /= Nothing)
          (Left ("BEAM eventual model " ++ machineName machine ++ " needs abstract to compare the final state"))
        spec <- machineSpec bits datas (C.unitDeclarations unit) (C.unitContracts unit) machine
        start <- case machineStart machine of
          Just s -> E.tuple <$> mapM callback [startRun s,startModel s]
          Nothing -> Left "a BEAM model needs a start command"
        commands <- forM (machineCommands machine) $ \c -> do
          run <- callback (commandRun c)
          reference <- callback (commandReference c)
          when <- optional (commandWhen c)
          pure (E.tuple [run,reference,when])
        abstract <- optional (machineAbstractRun machine)
        let invariant (OnModel f) = f
            invariant (OnState f) = f
        invariants <- mapM (callback . invariant) (machineInvariants machine)
        ds <- mapM declaration (nub (foldr (:) [] machine))
        factories <- Effects.factories units symbols [(a,C.ProductionHandler) | a <- nub (concatMap Effects.uses ds)]
        let scenarioNames = map ((name ++ "_scenario_") ++) (map (drop 4)
              (unitTestNames target (map P.programTitle (machineScenarios machine))))
        scenarios <- forM (zip scenarioNames (machineScenarios machine)) $ \(entry,program) -> do
          wire <- scenarioWire bits datas (concatMap C.unitSessions units) program
          let description = P.programSpec (program {P.programWire = wire})
          pure (entry, C.idText (C.unitId unit) ++ "::scenario " ++ P.programTitle program,
            E.remote "lawspec_beam_scenario" "check" [E.call name [],E.binary description])
        let body = E.apply (D.text "_LsBody") [E.tuple [schema,symbols]]
            handled = if null (concatMap Effects.uses ds) then E.apply (E.lambda [schema] body) [D.text "_LsBaseSchema"]
              else E.remote "lawspec_beam_effects" "with_scope" [D.text "_LsBaseSchema",factories,E.lambda [schema] body]
            scoped = if hasPolicies then E.remote "lawspec_beam_workflow" "with_test_runtime" [E.lambda [] handled] else handled
            context = E.lambda [D.text "_LsBody"] (E.sequenceDoc
              [symbols <> D.text " = make_ref()",
               D.text "_LsBaseSchema = " <> E.remote "lawspec_data" "schema" [symbols],scoped])
            model = E.remote "maps" "put" [E.atom "context",context,
              E.remote "lawspec_beam_model" "new" [E.binary spec,start,E.array commands,abstract,E.array invariants]]
            label = C.idText (C.unitId unit) ++ "::model " ++ machineName machine
            cases = [(name ++ "_sequential", label, E.remote "lawspec_beam_model" "check" [E.call name []])] ++
              [(name ++ "_parallel", label ++ " parallel", E.remote "lawspec_beam_model_parallel" "check" [E.call name []]) | machineShared machine] ++ scenarios
            functions = [E.function name [] [model]] ++ caseFunctions cases
        pure (cases,functions)
      let supervision = [("supervision", C.idText (C.unitId unit) ++ "::supervision",
              E.remote "lawspec_beam_supervision" "check" []) | not (null (C.unitSupervisors unit))]
          cases = concatMap fst prepared ++ supervision
          exports = [(entry,0) | (entry,_,_) <- cases] ++ [(entry ++ "_test_",0) | (entry,_,_) <- cases, target == "erlang"]
          erlang = Artifact (testSupport ++ moduleName ++ ".erl")
            (D.render layout (E.moduleDoc moduleName exports (concatMap snd prepared ++ caseFunctions supervision))) "generated" "test"
          elixir = Artifact ("test/" ++ moduleName ++ "_test.exs")
            (D.render layout (X.moduleDoc (E.nativeModule "elixir" unit ++ ".LawSpecModelTest") False
              (D.text "use ExUnit.Case" : [D.text "test " <> X.string title <> D.text " do" <>
                D.nest 2 (D.hardline <> X.remote (":" ++ moduleName) entry []) <> D.hardline <> D.text "end"
                | (entry,title,_) <- cases]))) "generated" "test"
          gleam = Artifact ("test/" ++ moduleName ++ "_test.gleam")
            (D.render layout (G.fileDoc False [G.external moduleName entry (entry ++ "_test") [] (D.text "Nil")
              | (entry,_,_) <- cases])) "generated" "test"
      pure (erlang : [elixir | target == "elixir"] ++ [gleam | target == "gleam"])
