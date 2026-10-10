-- | Native Erlang artifacts and PropEr tests from a fully elaborated plan.
-- The other BEAM languages share this runtime and the Core expression layer.
-- ref:DEC-typed-core-boundary ref:DEC-native-property-frameworks
module LawSpec.BeamEmit (emitBeam, emitBeamWithBindings) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine (machineActor, machineScenarios)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamProperties as Properties
import qualified LawSpec.BeamData as Data
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import qualified LawSpec.BeamActors as Actors
import qualified LawSpec.BeamModels as Models
import qualified LawSpec.BeamModelChecks as ModelChecks
import qualified LawSpec.BeamMailboxes as Mailboxes
import qualified LawSpec.BeamSessions as Sessions
import qualified LawSpec.BeamRemote as Remote
import qualified LawSpec.Network as Network
import qualified LawSpec.Resources as Resources
import qualified LawSpec.Matchers as Matchers
import qualified LawSpec.Collections as Collections
import qualified LawSpec.Resilience as Resilience
import qualified LawSpec.BeamNativeBinding as Native
import qualified LawSpec.ElixirNative as Elixir
import qualified LawSpec.GleamNative as Gleam
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Testing
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.DefaultSources (defaultSource)
import LawSpec.NativeRequest (BindingPlan, emptyBindingPlan, hasBindings)
import Control.Monad (unless, forM)
import Data.List (nub, isPrefixOf)

emitBeam :: String -> Bool -> Plan -> Either [Diagnostic] [Artifact]
emitBeam target minify = emitBeamWithBindings target minify emptyBindingPlan

emitBeamWithBindings :: String -> Bool -> BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitBeamWithBindings target minify bindings plan = do
  diagnose "target" (validatePlan target plan)
  bound <- diagnose "native-binding" $ if hasBindings bindings then Native.emitBindings target layout bindings plan else pure []
  ordinary <- diagnose "target" emit
  diagnose "native-binding" $ unless (length (map artifactPath (ordinary ++ bound)) == length (nub (map artifactPath (ordinary ++ bound))))
    (Left "BEAM native bindings produce conflicting artifact paths")
  pure (ordinary ++ bound)
  where
    diagnose code = either (Left . pure . (\message -> Diagnostic code message Nothing)) Right
    emit = do
      names <- E.dataNames declarations
      schemaFile <- Data.emitData target layout bits declarations
      definitions <- Definitions.emitDefinitions target layout bits declarations units (Native.boundEntries bindings)
      abilities <- if hasAbilities then Abilities.emit target layout bits declarations units (hasBindings bindings) else pure []
      actors <- Actors.emit target layout bits declarations units
      mailboxes <- Mailboxes.emit target layout bits declarations units
      sessions <- Sessions.emit target layout bits declarations units
      remotes <- Remote.emit target layout plan
      adapters <- mapM (adapter names) [u | u <- units, target == "erlang", not (boundUnit u),
        not (null (adapterDeclarations u) && null (Abilities.productionAbilities u))]
      native <- case target of
        "elixir" -> Elixir.emitNative layout bits declarations units
        "gleam" -> Gleam.emitNative layout declarations units
        _ -> pure []
      tests <- Properties.emit target layout bindings plan
      models <- Models.emit target layout bits declarations units
      pure (schemaFile : definitions ++ abilities ++ actors ++ mailboxes ++ sessions ++ remotes ++ adapters ++ [a | a <- native, artifactPath a `notElem` boundPaths] ++
        tests ++ models ++ runtimes ++ modelRuntimes ++ testRuntimes ++ cryptoAssets ++ generators (tests ++ models))
    testRuntimes = [Artifact (testSupport ++ "lawspec_beam_" ++ name ++ ".erl")
      (runtimeSource ("beam-" ++ name)) "generated" "test"
      | name <- ["report"] ++ ["coverage" | target == "gleam"] ++ ["test_run" | target == "gleam" || target == "erlang" && any (\u -> not (null (plannedProperties u)) || not (null (ModelChecks.checks (plannedUnit u))) ||
          maybe False (not . null . C.harnessBenchmarks) (C.unitHarnessSettings (plannedUnit u))) (plannedUnits plan)] ++
          (if hasCaseSupervision then ["resource", "resources"] else [])]
    hasCaseSupervision = any (\p -> not (null (C.propertyResources (plannedProperty p))) ||
      C.harnessTimeout (C.propertyHarness (plannedProperty p)) /= Nothing)
      (concatMap plannedProperties (plannedUnits plan))
    modelRuntimes = [Artifact (testSupport ++ "lawspec_beam_" ++ name ++ ".erl")
      (runtimeSource ("beam-" ++ name)) "generated" "test"
      | any (not . null . C.unitMachines) units,
        name <- ["model","model_parallel","values"] ++ ["random" | not hasPolicies] ++
          ["tasks" | not hasPolicies && not hasActors] ++
          (if any (not . null . machineScenarios) (concatMap C.unitMachines units)
            then ["history","scenario","scenario_io","scenario_network","wire","memory_network","channel_protocol","node","transport","endpoint"] else []),
        name `notElem` runtimeNames] ++
      [Artifact (testSupport ++ "lawspec_beam_supervision.erl") (runtimeSource "beam-supervision") "generated" "test"
        | any (not . null . C.unitSupervisors) units]
    runtimes = [Artifact ("src/lawspec_beam_" ++ name ++ ".erl")
        (runtimeSource ("beam-" ++ name)) "generated" "source"
        | name <- runtimeNames] ++
        [Artifact "src/lawspec_network.erl" (runtimeSource "beam-network-api") "generated" "source" | hasNodes] ++
        [Artifact "lib/lawspec/network.ex" (runtimeSource "beam-elixir-network") "generated" "source"
          | target == "elixir", hasNodes] ++
        [Artifact "lib/lawspec/workflow.ex" (runtimeSource "beam-elixir-workflow") "generated" "source"
          | target == "elixir", hasPolicies] ++
        [Artifact "lib/lawspec/sessions.ex" (runtimeSource "beam-elixir-sessions") "generated" "source"
          | target == "elixir", hasSessions] ++
        [Artifact ("src/lawspec/" ++ name ++ ".gleam") (runtimeSource ("beam-gleam-" ++ name)) "generated" "source"
          | name <- ["types","scalar"] ++ ["failures" | usesEffects] ++ ["effects" | hasAbilities] ++
              ["workflow" | hasPolicies] ++ ["actors" | hasActors] ++ ["network" | hasNodes] ++
              ["sessions" | hasSessions], target == "gleam"]
    runtimeNames = nub (["scalar","schema","regex","runtime","values","recorded"] ++
            (if usesEffects then ["effects","handler","waits"] else []) ++
            ["defaults" | hasPolicies || any Abilities.hasDefault (Effects.abilities units)] ++
            ["tasks" | hasPolicies || hasActors || hasMailboxes || hasSessions || hasRemotes || usesNetwork] ++
            ["transport" | hasActors || hasMailboxes || hasSessions || hasRemotes || usesNetwork] ++
            (if hasPolicies then ["random","policy","attempts","workflow_state","workflow"] else []) ++
            (if hasActors then ["actors","actor","actor_sup","actor_tree"] else []) ++
            (if hasMailboxes then ["mailbox","values","wire","random","memory_network","node"] else []) ++
            (if hasSessions then ["session","session_task","session_ownership","session_network",
              "values","wire","random","memory_network","node","endpoint","channel_protocol"] else []) ++
            (if hasRemotes || hasActors then ["remote","values","wire","random","memory_network","node"] else []) ++
            (if usesNetwork then ["network","network_crypto","network_config","socket_transport","socket_protocol",
              "values","wire","random","memory_network","node"] else []) ++
            (if usesCrypto then ["crypto","crypto_native"] else []) ++
            ["gleam" | target == "gleam"])
    usesNetwork = Network.usesNetworkUnits units
    usesCrypto = usesNetwork || any ((== "lawspec.crypto") . C.idText . C.unitId) units
    cryptoAssets = if not usesCrypto then [] else
      [Artifact "priv/lawspec_crypto_native.c" (runtimeSource "beam-crypto-native-c") "generated" "source",
       Artifact "lawspec_crypto_build.escript" (runtimeSource "beam-crypto-build") "generated" "source",
       Artifact (testSupport ++ "lawspec_beam_crypto_vectors.erl") vectorSource "generated" "test",
       vectorTests]
    vectorSource = unlines [if line == "vector_text() -> @@VECTORS@@."
      then "vector_text() -> " ++ D.render layout (E.binary (defaultSource "vectors.txt")) ++ "." else line
      | line <- lines (defaultSource "beam/crypto_vectors.erl")]
    vectorKinds = ["sha3-256","shake256","aes-256-gcm","mlkem768-keygen","mlkem768-encaps",
      "mlkem768-decaps","mlkem768-decaps-seed","mldsa65-keygen","mldsa65-verify",
      "mldsa65-sign-seed","slhdsa128f-keygen","slhdsa128f-verify"]
    vectorTests = case target of
      "elixir" -> Artifact "test/lawspec_crypto_vectors_test.exs"
        (D.render layout (X.moduleDoc "LawSpec.CryptoVectorsTest" False (D.text "use ExUnit.Case" :
          [D.text "test " <> X.string kind <> D.text " do" <> D.nest 2 (D.hardline <>
            X.remote ":lawspec_beam_crypto_vectors" "check" [X.string kind]) <> D.hardline <> D.text "end" | kind <- vectorKinds]))) "generated" "test"
      "gleam" -> Artifact "test/lawspec_crypto_vectors_test.gleam"
        (D.render layout (G.fileDoc False (G.external "lawspec_beam_crypto_vectors" "check" "check" [D.text "kind: String"] (D.text "Nil") :
          [G.function (E.snake kind ++ "_test") [] (D.text "Nil") [G.call "check" [G.string kind]] | kind <- vectorKinds]))) "generated" "test"
      _ -> Artifact "test/lawspec_crypto_vectors_tests.erl"
        (D.render layout (E.moduleDoc "lawspec_crypto_vectors_tests" [("crypto_vectors_test_",0)]
          [E.function "crypto_vectors_test_" [] [E.array [E.tuple [D.text (show kind),
            E.lambda [] (E.remote "lawspec_beam_crypto_vectors" "check" [E.binary kind])] | kind <- vectorKinds]]])) "generated" "test"
    hasAbilities = not (null (Effects.abilities units) && null (Effects.handlers units))
    hasPolicies = any ((/= Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units)
    hasActors = any (any machineActor . C.unitMachines) units || any (not . null . C.unitSupervisors) units
    hasMailboxes = any (not . null . C.unitMailboxes) units
    hasSessions = any (not . null . C.unitSessions) units
    hasRemotes = Remote.available plan
    hasNodes = hasActors || hasMailboxes || hasSessions || hasRemotes || usesNetwork
    usesEffects = any (not . null . C.unitAbilities) units ||
      any (not . null . C.declarationUses) (concatMap C.unitDeclarations units)
    generators tests = if null tests then [] else
        [Artifact (testSupport ++ "lawspec_beam_" ++ name ++ ".erl") (runtimeSource ("beam-" ++ name)) "generated" "test"
          | name <- ["generators", "index", "harness", "schedule"]] ++
        [Artifact "test/lawspec_beam_proper.erl" (runtimeSource "beam-proper") "generated" "test" | target == "erlang"] ++
        [Artifact "test/support/lawspec_beam_stream_data.ex" (runtimeSource "beam-stream-data") "generated" "test" | target == "elixir"] ++
        [Artifact "test/support/lawspec_beam_exunit_formatter.ex" (runtimeSource "beam-exunit-formatter") "generated" "test" | target == "elixir"] ++
        [Artifact "test/support/lawspec_beam_exunit_schedule.ex" (runtimeSource "beam-exunit-schedule") "generated" "test" | target == "elixir"] ++
        [Artifact (testSupport ++ "lawspec_beam_tasks.erl") (runtimeSource "beam-tasks") "generated" "test"
          | target == "elixir" || hasCaseSupervision, "tasks" `notElem` runtimeNames,
            (testSupport ++ "lawspec_beam_tasks.erl") `notElem` map artifactPath modelRuntimes] ++
        [Artifact "test-support/src/lawspec_beam_qcheck.erl" (runtimeSource "beam-qcheck") "generated" "test" | target == "gleam"] ++
        [Artifact (testSupport ++ "lawspec_beam_" ++ name ++ ".erl") (runtimeSource ("beam-" ++ name)) "generated" "test"
          | any ((/= Nothing) . Properties.searchDescriptors plan)
              (concatMap plannedProperties (plannedUnits plan)),
            name <- ["search","values","random"], name `notElem` runtimeNames,
            (testSupport ++ "lawspec_beam_" ++ name ++ ".erl") `notElem` map artifactPath modelRuntimes]
    declarations = planDataDeclarations plan
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    boundUnit u = any ((`elem` map fst (Native.boundEntries bindings)) . C.declarationId) (C.unitDeclarations u)
    boundPaths = [boundPath u | u <- units, boundUnit u]
    boundPath u = case target of
      "elixir" -> "lib/" ++ E.moduleName (C.unitId u) ++ ".ex"
      "gleam" -> "src/" ++ E.gleamPath (C.unitId u) ++ ".gleam"
      _ -> "src/" ++ E.moduleName (C.unitId u) ++ ".erl"
    layout = D.selectLayout minify (D.Pretty 100)
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    adapterDeclarations u = [d | d <- C.unitDeclarations u,
      C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]
    adapter names unit = do
      functions <- fmap concat $ forM (adapterDeclarations unit) $ \d -> do
        signature <- Definitions.declarationSpec bits names units d
        let args = [D.text ("_Argument" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType (C.declarationType d)))]
            handlers = [D.text ("_Handler" ++ show i) | (i,_) <- zip [0::Int ..] (Effects.uses d)]
        pure [signature,E.function (E.functionName d) (handlers ++ args) [E.remote "erlang" "error"
          [E.tuple [E.atom "not_implemented",E.binary (C.idText (C.declarationId d))]]]]
      production <- concat <$> mapM (Abilities.productionStub target bits names) (Abilities.productionAbilities unit)
      let name = Definitions.adapterModule unit
          exports = [(E.functionName d,length (Effects.uses d) + length (fst (C.functionType (C.declarationType d)))) | d <- adapterDeclarations unit] ++
            concatMap Abilities.productionExports (Abilities.productionAbilities unit)
          -- The adapter is editable; both layouts retain its readable baseline.
          body = (if Abilities.defaultUnit unit then E.moduleDoc else E.userModuleDoc) name exports (functions ++ production)
      pure (if Abilities.defaultUnit unit then Artifact ("src/" ++ name ++ ".erl") (D.render layout body) "generated" "source"
        else AdapterArtifact ("src/" ++ name ++ ".erl") (D.render layout body)
          "user" "source" (D.render (D.Pretty 100) body))

-- | Until each execution plane is connected, compilation diagnoses it. No
-- law, policy, recording or resource may silently disappear from a release.
-- ref:DEC-never-pass-vacuously
validatePlan :: String -> Plan -> Either String ()
validatePlan target plan = do
  let units = map plannedUnit (plannedUnits plan)
      declarations = concatMap C.unitDeclarations units
      moduleNames = map (Definitions.adapterModule) units
      generated = ["lawspec_data","lawspec_definitions","lawspec_abilities","lawspec_native_bindings","lawspec_native_generators"] ++
        [Definitions.adapterModule u ++ suffix | u <- units, suffix <-
          ["_definitions","_definitions_ffi","_lawspec_tests","_lawspec_cases","_lawspec_models","_lawspec_models_test"]] ++
        ["lawspec_abilities_" ++ Definitions.adapterModule u | u <- units]
      collisions = [n | n <- moduleNames, n `elem` generated || "lawspec_beam_" `isPrefixOf` n]
      natives = [E.nativeModule target u | u <- units,
        not (null (C.unitDeclarations u) && null (Abilities.productionAbilities u))]
      nativeGenerated = [E.nativeModule target u ++ suffix | u <- units, suffix <- [".Definitions", ".LawSpecTest", ".LawSpecModelTest"]]
      functionClashes u = let names = map (E.nativeFunction target) (C.unitDeclarations u) ++
                               map Abilities.productionName (Abilities.productionAbilities u)
                         in length names /= length (nub names)
  unless (length moduleNames == length (nub moduleNames) && null collisions && all (not . null) moduleNames)
    (Left "BEAM module names collide after snake_case conversion or with generated runtime modules")
  unless (length natives == length (nub natives) && (target /= "elixir" ||
    all (\n -> not ("Elixir.LawSpec." `isPrefixOf` n) && n `notElem` nativeGenerated) natives))
    (Left "Elixir module names collide after normalization or with the LawSpec namespace")
  unless (target /= "gleam" || all (\n -> (not ("lawspec@" `isPrefixOf` n) ||
    n `elem` [E.nativeModule target u | u <- units,
      Abilities.defaultUnit u || C.idText (C.unitId u) `elem`
        [Resilience.resilienceUnit,Resources.resourcesUnit,Matchers.matchersUnit,Collections.collectionsUnit]]) &&
    n `notElem` [E.nativeModule target u ++ "@definitions" | u <- units]) natives)
    (Left "Gleam module names collide with generated modules or the lawspec namespace")
  unless (all ((<= 230) . length) (moduleNames ++ generated ++ natives) &&
    all (\d -> length (Effects.uses d) + length (fst (C.functionType (C.declarationType d))) <= 253) declarations)
    (Left "BEAM module name or function arity exceeds the Erlang limit")
  unless (all (\d -> let n = E.nativeFunction target d in not (null n) && length n <= 255) declarations)
    (Left "BEAM function name is empty or exceeds the Erlang atom limit")
  unless (not (any functionClashes units)) (Left "BEAM function names collide after snake_case conversion")
