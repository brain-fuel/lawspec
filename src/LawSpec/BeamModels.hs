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
import qualified LawSpec.BeamModelChecks as Checks
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import LawSpec.MachineSpec (machineSpec, scenarioWire)
import LawSpec.Common (Artifact(..))
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
    unitFiles unit = do
      let moduleName = Definitions.adapterModule unit ++ "_lawspec_models"
          names = Checks.machineNames unit
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
        let body = E.apply (D.text "_LsBody") [E.tuple [schema,symbols]]
            handled = if null (concatMap Effects.uses ds) then E.apply (E.lambda [schema] body) [D.text "_LsBaseSchema"]
              else E.remote "lawspec_beam_effects" "with_scope" [D.text "_LsBaseSchema",factories,E.lambda [schema] body]
            scoped = if hasPolicies then E.remote "lawspec_beam_workflow" "with_test_runtime" [E.lambda [] handled] else handled
            context = E.lambda [D.text "_LsBody"] (E.sequenceDoc
              [symbols <> D.text " = make_ref()",
               D.text "_LsBaseSchema = " <> E.remote "lawspec_data" "schema" [symbols],scoped])
            model = E.remote "maps" "put" [E.atom "context",context,
              E.remote "lawspec_beam_model" "new" [E.binary spec,start,E.array commands,abstract,E.array invariants]]
        pure (E.function name [] [model])
      let checks = Checks.checks unit
      cases <- forM checks $ \check -> do
        action <- case Checks.checkAction check of
          Checks.Sequential name _ -> pure (E.remote "lawspec_beam_model" "check" [E.call name []])
          Checks.Parallel name _ -> pure (E.remote "lawspec_beam_model_parallel" "check" [E.call name []])
          Checks.Scenario name _ program -> do
            wire <- scenarioWire bits datas (concatMap C.unitSessions units) program
            pure (E.remote "lawspec_beam_scenario" "check"
              [E.call name [], E.binary (P.programSpec (program {P.programWire = wire}))])
          Checks.Supervision -> pure (E.remote "lawspec_beam_supervision" "check" [])
        pure (E.function (Checks.checkName check) [] [action,E.atom (if target == "gleam" then "nil" else "ok")])
      pure [Artifact (testSupport ++ moduleName ++ ".erl")
        (D.render layout (E.moduleDoc moduleName [(Checks.checkName c,0) | c <- checks] (prepared ++ cases))) "generated" "test"]
