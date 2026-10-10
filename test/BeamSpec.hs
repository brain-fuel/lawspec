-- | BEAM generation consumes the same checked plan and retains native source
-- ownership and every planned case. ref:DEC-tests-cite-requirements
module BeamSpec (test_beamCodeUsesCheckedCoreAndNativeFrameworks) where

import Test.Hspec
import Data.List (isInfixOf, nub)
import Data.Either (isLeft)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (planTesting, Plan(..), PlannedUnit(..), PlannedProperty(..), GeneratorRequirement(..))
import LawSpec.CoreEmit (emitPlanWithFormat, emitPlanWithOptions)
import LawSpec.TestManifest (unitTestPath)
import qualified LawSpec.TestManifest as TestManifest
import LawSpec.TestNames (unitTestNames)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Machine as Machine
import qualified LawSpec.Core.Program as Program
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamActors as Actors
import qualified LawSpec.BeamModels as Models
import qualified LawSpec.BeamModelChecks as ModelChecks
import qualified LawSpec.BeamMailboxes as Mailboxes
import qualified LawSpec.BeamSessions as Sessions
import qualified LawSpec.BeamRemote as Remote
import qualified LawSpec.BeamProperties as Properties
import qualified LawSpec.BeamGenerators as Generators
import LawSpec.NativeRequest (emptyBindingPlan)
import qualified LawSpec.Remote as Manifest
import LawSpec.Scaffold (scaffoldFilesWith)

generated :: Bool -> String -> Either [Diagnostic] [Artifact]
generated = generatedFor "erlang"

generatedFor :: String -> Bool -> String -> Either [Diagnostic] [Artifact]
generatedFor target compact text = compileCore 64 defaultGeneration [Source "beam.lawspec" text]
  >>= planTesting >>= emitPlanWithFormat compact target

test_beamCodeUsesCheckedCoreAndNativeFrameworks :: Spec
test_beamCodeUsesCheckedCoreAndNativeFrameworks = describe "BEAM generation" $ do
  -- ref:DEC-shrink-within-domain ref:DEC-native-property-frameworks
  it "passes safe sequence lengths to native generators without requiring an example" $ do
    let source = unlines ["unit example.lengths",
          "law `length` is definition is `for all` (x :: Bytes where prelude.length x == 3) . x = x end end"]
    case compileCore 64 defaultGeneration [Source "lengths.lawspec" source] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\p -> case Generators.inputs "framework" (D.text "Schema") (D.text "Symbols") plan (const "Input") p of
        Left message -> expectationFailure message
        Right body -> D.render D.Compact body `shouldSatisfy` isInfixOf
          "{length, <<\"==\"/utf8>>, lawspec_beam_schema:validate(3,")
        (concatMap plannedProperties (plannedUnits plan))
  it "passes same-type fixture hints independently of comparison bounds" $ do
    let source = unlines ["unit example.hints",
          "law `symbol` is definition is `for all` (x :: Symbol where x == symbol(\"selected\", \"fixture\")) . x = x end end"]
    case compileCore 64 defaultGeneration [Source "hints.lawspec" source] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\p ->
        let hintOnly = p {generatorRequirements = [r {generatorPredicates = [], generatorBounds = []} | r <- generatorRequirements p]}
        in case Generators.inputs "framework" (D.text "Schema") (D.text "Symbols") plan (const "Input") hintOnly of
          Left message -> expectationFailure message
          Right body -> D.render D.Compact body `shouldSatisfy` isInfixOf "selected")
        (concatMap plannedProperties (plannedUnits plan))
  mapM_ (\predicate -> it ("keeps guarded length refinements in the predicate: " ++ predicate) $ do
    let source = unlines ["unit example.guardedLengths",
          "law `length` is definition is `for all` (n :: Int8) (x :: Bytes where " ++ predicate ++ ") . x = x end end"]
    case compileCore 64 defaultGeneration [Source "guarded.lawspec" source] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\p -> case Generators.inputs "framework" (D.text "Schema") (D.text "Symbols") plan (("V" ++) . E.pascal . C.idText) p of
        Left message -> expectationFailure message
        Right body -> D.render D.Compact body `shouldSatisfy` (not . isInfixOf "{length,"))
        (concatMap plannedProperties (plannedUnits plan)))
    ["prelude.length x == 3 || prelude.length x == 5", "n != 0 && prelude.length x == 10 / n"]
  -- ref:REQ-law-primitives
  mapM_ (\target -> it (target ++ " includes portable rendering for recorded table and description examples") $ do
    input <- readFile "examples/specs/tables.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        map artifactPath artifacts `shouldContain` ["src/lawspec_beam_recorded.erl"]
        concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "lawspec_beam_runtime:recorded"
        concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "example.tables/first label"
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-distribution-canonical-wire ref:DEC-typed-core-boundary
  mapM_ (\target -> it (target ++ " includes secure transport and the seed bridge only with a network import") $ do
    let input = "unit example.network\ndefinition same (n :: Int32) :: Int32 is n end\n"
    case (generatedFor target False input, generatedFor target False ("unit example.network\nimport lawspec.network\ndefinition same (n :: Int32) :: Int32 is n end\n")) of
      (Right plain, Right secure) -> do
        let paths = map artifactPath secure
        mapM_ (\path -> paths `shouldContain` [path])
          ["src/lawspec_beam_transport.erl", "src/lawspec_beam_network.erl", "src/lawspec_beam_network_crypto.erl",
           "src/lawspec_beam_network_config.erl", "src/lawspec_beam_socket_transport.erl", "src/lawspec_beam_socket_protocol.erl",
           "src/lawspec_network.erl", "priv/lawspec_crypto_native.c", "lawspec_crypto_build.escript"]
        map artifactPath plain `shouldNotContain` ["src/lawspec_beam_network.erl"]
        map artifactPath plain `shouldNotContain` ["src/lawspec_beam_socket_transport.erl"]
        map artifactPath plain `shouldNotContain` ["priv/lawspec_crypto_native.c"]
        map artifactPath plain `shouldContain` ["src/lawspec_network.erl"]
        case target of
          "elixir" -> paths `shouldContain` ["lib/lawspec/network.ex"]
          "gleam" -> paths `shouldContain` ["src/lawspec/network.gleam"]
          _ -> pure ()
      (Left errors, _) -> expectationFailure (show errors)
      (_, Left errors) -> expectationFailure (show errors)
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-distribution-canonical-wire ref:DEC-native-bindings-typed-identity
  mapM_ (\target -> it (target ++ " emits remote definition hashes and native server ability parameters") $ do
    input <- readFile "acceptance/beam-remote-api/remote.lawspec"
    case compileCore 64 defaultGeneration [Source "remote.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Remote.emit target (D.Pretty 100) plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
              remotes = snd (Manifest.remoteManifest plan)
          length remotes `shouldBe` 3
          mapM_ (\remote -> body `shouldSatisfy` isInfixOf (Manifest.remoteDigest remote)) remotes
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_remote:serve", "lawspec_beam_remote:call", "lawspec_beam_effects:with_native_context",
             "lawspec_definitions:evaluate_", "shifted_with_timeout", "lawspec_beam_schema:from_native",
             "lawspec_beam_schema:to_native", "lawspec_beam_schema:validate"]
          case target of
            "elixir" -> body `shouldSatisfy` isInfixOf "LawSpec.Remote.Example.Remote"
            "gleam" -> body `shouldSatisfy` isInfixOf "data.Parcel"
            _ -> body `shouldSatisfy` isInfixOf "serve/2"
    ) ["erlang", "elixir", "gleam"]
  it "rejects colliding generated remote timeout methods" $ do
    let input = unlines ["unit example.collision", "definition f (n :: Int32) :: Int32 is n end",
          "definition fWithTimeout (n :: Int32) :: Int32 is n end"]
    case compileCore 64 defaultGeneration [Source "remote.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\target -> Remote.emit target (D.Pretty 100) plan `shouldSatisfy` isLeft)
        ["erlang", "elixir", "gleam"]
  -- ref:DEC-sessions-by-construction ref:DEC-idiomatic-generated-types
  mapM_ (\target -> it (target ++ " emits opaque session steps and typed delegation with native tasks") $ do
    input <- readFile "examples/specs/sessions.lawspec"
    case compileCore 64 defaultGeneration [Source "sessions.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Sessions.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["first_receive_0", "first_receive_1", "first_send_2", "lawspec_beam_session:send_end",
             "lawspec_beam_session:receive_end", "lawspec_beam_session_task:start", "lawspec_beam_schema:from_native",
             "lawspec_beam_session:listen", "lawspec_beam_session:dial"]
          case target of
            "elixir" -> body `shouldSatisfy` isInfixOf "LawSpec.Sessions.Example.Sessions.Serve.first_0()"
            "gleam" -> do
              body `shouldSatisfy` isInfixOf "session_types.LawspecSessionExampleSessionsServeFirst0"
              body `shouldSatisfy` (not . isInfixOf "import lawspec/sessions/example/sessions/serve")
            _ -> body `shouldSatisfy` isInfixOf "-opaque first_0()"
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction
  it "emits network session methods only when every nested protocol has wire types" $ do
    input <- readFile "acceptance/beam-session-api/sessions.lawspec"
    let extra = "\nprotocol NonwireChild is send Symbols end\n"
    case compileCore 64 defaultGeneration [Source "sessions.lawspec" (input ++ extra)] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Sessions.emit "erlang" (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body suffix = concat [artifactContent a | a <- artifacts,
                artifactPath a == "src/lawspec_session_example_session_types_" ++ suffix ++ ".erl"]
          mapM_ (\name -> body name `shouldSatisfy` isInfixOf "lawspec_beam_session:listen") ["exchange", "loop_a", "loop_b"]
          mapM_ (\name -> body name `shouldSatisfy` (not . isInfixOf "lawspec_beam_session:listen")) ["symbols", "empty", "nonwire_child"]
  -- ref:DEC-distribution-canonical-wire ref:DEC-native-bindings-typed-identity
  it "escapes Gleam keywords in protocol, mailbox and unit paths and rejects resulting collisions" $ do
    let input = "unit example.echo\nprotocol Echo is send Int8 end\nmailbox echo of Int8\n"
    E.gleamPath (C.Id "echo.case") `shouldBe` "echo_lawspec/case_lawspec"
    case generatedFor "gleam" False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> mapM_ (\path -> map artifactPath artifacts `shouldContain` [path])
        ["src/lawspec/sessions/example/echo_lawspec/echo_lawspec.gleam",
         "src/lawspec/mailboxes/example/echo_lawspec/echo_lawspec.gleam"]
    generatedFor "gleam" False (input ++ "protocol EchoLawspec is send Int8 end\n") `shouldSatisfy` isLeft
    generatedFor "gleam" False (input ++ "mailbox echo_lawspec of Int8\n") `shouldSatisfy` isLeft
  -- ref:DEC-distribution-canonical-wire ref:DEC-native-bindings-typed-identity
  mapM_ (\target -> it (target ++ " emits typed local and remote mailboxes with checked Clock interfaces") $ do
    input <- readFile "acceptance/beam-mailbox-api/mailboxes.lawspec"
    case compileCore 64 defaultGeneration [Source "mailboxes.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Mailboxes.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
              localOnly = concatMap artifactContent [a | a <- artifacts, "identities" `isInfixOf` artifactPath a]
          all ((== "source") . artifactPlacement) artifacts `shouldBe` True
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_mailbox:serve", "lawspec_beam_mailbox:connect", "lawspec_beam_schema:from_native",
             "lawspec_beam_schema:to_native", "lawspec_beam_effects:with_native_context", "receive_with_clock"]
          localOnly `shouldSatisfy` (not . isInfixOf "send_remote")
          case target of
            "elixir" -> body `shouldSatisfy` isInfixOf "LawSpec.Mailboxes.Example.Mailboxes.JobsMailbox"
            "gleam" -> body `shouldSatisfy` isInfixOf "option.Option(data.Job)"
            _ -> body `shouldSatisfy` isInfixOf "-opaque sender()"
    ) ["erlang", "elixir", "gleam"]
  it "rejects mailbox names that collide after BEAM normalization" $ do
    let input = "unit demo.mail\nmailbox jobQueue of Int32\nmailbox job_queue of Int32\n"
    case compileCore 64 defaultGeneration [Source "mailboxes.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\target -> Mailboxes.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
        (map plannedUnit (plannedUnits plan)) `shouldSatisfy` \result -> case result of
          Left message -> "mailbox module names collide" `isInfixOf` message
          Right _ -> False) ["erlang", "elixir", "gleam"]
  -- ref:DEC-stateful-models-linearizability ref:DEC-typed-core-boundary
  mapM_ (\target -> it (target ++ " emits model evidence with checked callbacks and fresh native ability scopes") $ do
    input <- readFile "acceptance/beam-actor-api/actor_api.lawspec"
    case compileCore 64 defaultGeneration [Source "actor_api.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Models.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          all ((== "test") . artifactPlacement) artifacts `shouldBe` True
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_model:new", "lawspec_beam_model:check", "lawspec_beam_model_parallel:check",
             "lawspec_definitions:evaluate_", "lawspec_beam_effects:with_scope", "_production", "make_ref()"]
          body `shouldSatisfy` isInfixOf "model_counter__parallel()"
          body `shouldSatisfy` (not . isInfixOf "_test_()")
          case Properties.emit target (D.Pretty 100) emptyBindingPlan plan of
            Left message -> expectationFailure message
            Right cases -> do
              let native = concatMap artifactContent cases
              native `shouldSatisfy` isInfixOf "example_actor_abilities_lawspec_models:model_counter__parallel()"
              native `shouldSatisfy` isInfixOf "example.actor_abilities::model_counter__parallel"
              case target of
                "elixir" -> native `shouldSatisfy` isInfixOf "use ExUnit.Case"
                "gleam" -> native `shouldSatisfy` isInfixOf "model_counter__parallel__case_0_test() -> Nil"
                _ -> native `shouldSatisfy` isInfixOf "model_counter__parallel_cases()"
    ) ["erlang", "elixir", "gleam"]
  mapM_ (\target -> it (target ++ " emits scenarios with native model calls and complete wire descriptors") $ do
    input <- readFile "examples/specs/models.lawspec"
    case compileCore 64 defaultGeneration [Source "models.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Models.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          all ((== "test") . artifactPlacement) artifacts `shouldBe` True
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_scenario:check", "scenario_a_reply_is_delegated", "(wire (channel ask (send (end)))"]
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-actors-otp-supervision ref:DEC-native-bindings-typed-identity
  mapM_ (\target -> it (target ++ " emits supervision evidence even without a model in that unit") $ do
    input <- readFile "examples/specs/actors.lawspec"
    case compileCore 64 defaultGeneration [Source "actors.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> do
        let onlySupervisors = plan {plannedUnits = [u {plannedProperties = [],
              plannedUnit = (plannedUnit u) {C.unitMachines = [], C.unitProperties = []}} | u <- plannedUnits plan]}
            units = map plannedUnit (plannedUnits onlySupervisors)
        case Models.emit target (D.Pretty 100) 64 (planDataDeclarations plan) units of
          Left message -> expectationFailure message
          Right artifacts -> do
            let body = concatMap artifactContent artifacts
            all ((== "test") . artifactPlacement) artifacts `shouldBe` True
            body `shouldSatisfy` isInfixOf "lawspec_beam_supervision:check()"
            body `shouldSatisfy` (not . isInfixOf "lawspec_beam_model:check")
            body `shouldSatisfy` isInfixOf "supervision()"
            body `shouldSatisfy` (not . isInfixOf "_test_()")
            case Properties.emit target (D.Pretty 100) emptyBindingPlan onlySupervisors of
              Left message -> expectationFailure message
              Right cases -> do
                let native = concatMap artifactContent cases
                native `shouldSatisfy` isInfixOf "example.actors::supervision"
                native `shouldSatisfy` isInfixOf "example_actors_lawspec_models:supervision()"
                case target of
                  "erlang" -> native `shouldSatisfy` isInfixOf "lawspec_beam_test_run:select_units"
                  "elixir" -> native `shouldSatisfy` isInfixOf "use ExUnit.Case"
                  _ -> native `shouldSatisfy` isInfixOf "supervision__case_0_test() -> Nil"
    ) ["erlang", "elixir", "gleam"]
  mapM_ (\target -> it (target ++ " builds typed actor APIs through checked adapters and native OTP entry points") $ do
    input <- readFile "examples/specs/actors.lawspec"
    case compileCore 64 defaultGeneration [Source "actors.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Actors.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          let paths = map artifactPath artifacts
              body = concatMap artifactContent artifacts
          mapM_ (\path -> paths `shouldContain` [path])
            ["src/lawspec_actor_example_actors_account.erl","src/lawspec_supervisor_example_actors_bank.erl"]
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_definitions:evaluate_","lawspec_beam_schema:from_native", "lawspec_beam_schema:to_native",
             "lawspec_beam_actors:start_link", "otp_child_spec", "tell_deposit", "handlers := []",
             "lawspec_beam_remote:serve", "lawspec_beam_remote:call", "connect_with_timeout"]
          let remote = concatMap artifactContent [a | a <- artifacts,
                artifactPath a == "src/lawspec_actor_example_actors_account_remote.erl"]
          remote `shouldSatisfy` isInfixOf "-opaque t() :: lawspec_beam_remote:remote()"
          remote `shouldSatisfy` (not . isInfixOf "child_spec")
          body `shouldSatisfy` (not . isInfixOf "proper:")
          case target of
            "elixir" -> paths `shouldContain` ["lib/lawspec/actors/example/actors/account_actor.ex"]
            "gleam" -> paths `shouldContain` ["src/lawspec/actors/example/actors/account_actor.gleam"]
            _ -> pure ()
    ) ["erlang", "elixir", "gleam"]
  it "keeps actors with nonwireable messages local" $ do
    let input = unlines
          ["unit example.local", "type Box is Box value :: Int32 end", "openBox :: Unit -> Box",
           "notice :: Box -> Symbol -> Box", "definition ignored (s :: Symbol) (n :: Int32) :: Int32 is n end",
           "actor box :: Box by Int32 is", "start openBox by 0", "on notice by ignored", "end"]
    case compileCore 64 defaultGeneration [Source "local.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\target -> case Actors.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> concatMap artifactContent artifacts `shouldSatisfy` (not . isInfixOf "lawspec_beam_remote"))
        ["erlang", "elixir", "gleam"]
  it "threads BEAM ability interfaces through nested supervisors and actor methods" $ do
    input <- readFile "acceptance/beam-actor-api/actor_api.lawspec"
    case compileCore 64 defaultGeneration [Source "actor_api.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Actors.emit "gleam" (D.Pretty 100) 64 (planDataDeclarations plan)
          (map plannedUnit (plannedUnits plan)) of
        Left message -> expectationFailure message
        Right artifacts -> do
          mapM_ (\path -> map artifactPath artifacts `shouldContain` [path])
            ["src/lawspec_supervisor_example_actor_abilities_root.erl",
             "src/lawspec/supervisors/example/actor_abilities/bank_supervisor.gleam"]
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_supervisor_example_actor_abilities_bank:spec", "lawspec_beam_effects:with_native_context"]
  it "rejects BEAM actor methods that collide with lifecycle operations" $ do
    let input = unlines
          ["unit example.collision", "type Box is Box value :: Int32 end", "openBox :: Unit -> Box", "stop :: Box -> Box",
           "definition reset (n :: Int32) :: Int32 is 0 end", "actor box :: Box by Int32 is",
           "start openBox by 0", "on stop by reset", "end"]
    case compileCore 64 defaultGeneration [Source "collision.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> mapM_ (\target -> Actors.emit target (D.Pretty 100) 64 (planDataDeclarations plan)
        (map plannedUnit (plannedUnits plan)) `shouldSatisfy` \result -> case result of
          Left message -> "colliding BEAM API names" `isInfixOf` message
          Right _ -> False) ["erlang","elixir","gleam"]
  -- ref:DEC-domain-modeling-primitives ref:DEC-typed-core-boundary
  mapM_ (\target -> it (target ++ " emits workflow policies and scopes every generated case") $ do
    input <- readFile "examples/specs/workflows.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let paths = map artifactPath artifacts
            source = concatMap artifactContent artifacts
            tests = concatMap artifactContent (filter ((== "test") . artifactPlacement) artifacts)
        mapM_ (\name -> paths `shouldContain` ["src/lawspec_beam_" ++ name ++ ".erl"])
          ["policy","random","defaults","tasks","attempts","workflow_state","workflow"]
        source `shouldSatisfy` isInfixOf "lawspec_beam_workflow:run_stage"
        tests `shouldSatisfy` isInfixOf "lawspec_beam_workflow:with_test_runtime"
        if target == "erlang" then isInfixOf "timeout,\n" tests `shouldBe` True else pure ()
        if target == "gleam" then paths `shouldContain` ["src/lawspec/workflow.gleam"] else pure ()
    limits <- readFile "examples/specs/limits.lawspec"
    case generatedFor target False limits of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> concatMap artifactContent artifacts `shouldSatisfy`
        isInfixOf "lawspec_beam_workflow:run_workflow"
    case generatedFor target False "unit example.plain\ndefinition identity (x :: Int32) :: Int32 is x end\n" of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> map artifactPath artifacts `shouldSatisfy` all (not . isInfixOf "workflow")
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-typed-core-boundary ref:DEC-adapter-ownership
  mapM_ (\target -> it (target ++ " emits portable crypto defaults, a native bridge and every vector family") $ do
    input <- readFile "examples/specs/crypto.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let paths = map artifactPath artifacts
            bodies = concatMap artifactContent artifacts
        mapM_ (\path -> paths `shouldContain` [path])
          ["src/lawspec_beam_crypto.erl", "src/lawspec_beam_crypto_native.erl",
           "priv/lawspec_crypto_native.c", "lawspec_crypto_build.escript"]
        bodies `shouldSatisfy` isInfixOf "slh_dsa_signature_handler"
        bodies `shouldSatisfy` (not . isInfixOf "@@VECTORS@@")
        length (filter ((== "user") . ownership) artifacts) `shouldBe` 1
        let expected = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
        [(artifactPath a, artifactPlacement a) | a <- artifacts, "lawspec_beam_crypto_vectors.erl" `isInfixOf` artifactPath a]
          `shouldBe` [(expected ++ "lawspec_beam_crypto_vectors.erl", "test")]
        mapM_ (\kind -> bodies `shouldSatisfy` isInfixOf kind)
          ["sha3-256","shake256","aes-256-gcm","mlkem768-keygen","mlkem768-encaps",
           "mlkem768-decaps","mlkem768-decaps-seed","mldsa65-keygen","mldsa65-verify",
           "mldsa65-sign-seed","slhdsa128f-keygen","slhdsa128f-verify"]
    case generatedFor target False "unit example.plain\ndefinition identity (x :: Int32) :: Int32 is x end\n" of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> map artifactPath artifacts `shouldSatisfy` all (not . isInfixOf "crypto")
    let scaffold withCrypto = either error (concatMap snd) (scaffoldFilesWith withCrypto False target)
    scaffold False `shouldSatisfy` (not . isInfixOf "lawspec_crypto_build")
    if target /= "erlang" then pure () else mapM_ (\withCrypto ->
      scaffold withCrypto `shouldSatisfy` isInfixOf "{print_depth, 100}") [False, True]
    if target == "gleam" then pure () else scaffold True `shouldSatisfy` isInfixOf "lawspec_crypto_build.escript"
    if target == "gleam" then pure () else
      case compileCore 64 defaultGeneration [Source "crypto.lawspec" input] >>= planTesting >>=
          emitPlanWithOptions False target (Just "application") (Just "checks") of
        Left errors -> expectationFailure (show errors)
        Right artifacts -> do
          let paths = map artifactPath artifacts
          mapM_ (\path -> paths `shouldContain` [path])
            ["lawspec_crypto_build.escript", "priv/lawspec_crypto_native.c",
             "application/lawspec_beam_crypto_native.erl"]
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-typed-core-boundary ref:DEC-adapter-ownership
  mapM_ (\target -> it (target ++ " emits compiler-owned built-in factories and temporal laws") $ do
    input <- readFile "examples/specs/builtins.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        map artifactPath artifacts `shouldContain` ["src/lawspec_beam_defaults.erl"]
        let adapters = filter ((== "user") . ownership) artifacts
            generatedBodies = concatMap artifactContent (filter ((== "generated") . ownership) artifacts)
        length adapters `shouldBe` 1
        generatedBodies `shouldSatisfy` isInfixOf "default_lawspec_time_clock_handler"
        generatedBodies `shouldSatisfy` isInfixOf "default_lawspec_randomness_random_handler"
        generatedBodies `shouldSatisfy` isInfixOf "a deadline eventually passes"
        generatedBodies `shouldSatisfy` isInfixOf "a deadline is quick to make") ["erlang", "elixir", "gleam"]
  -- ref:DEC-typed-core-boundary
  it "passes each lexical handler scope to operations inside nested regions" $ do
    let ability = C.AbilityRef (C.Id "example::ability::Counter") []
        term node = C.Expr (C.scalarType "Integer") node (C.GeneratedFrom (C.Id "scope-test"))
        handled body = term (C.Handle (C.WithHandler ability (C.SpecHandler (C.Id "counter"))) body)
        body = handled (handled (term (C.Perform (C.Operation ability "read") [])))
        external schema expression values = pure (E.call
          (case C.expressionNode expression of C.Handle _ _ -> "scoped"; _ -> "read") (schema : values))
    case Expr.renderExpression 64 (D.text "_OuterSchema") (D.text "_Symbols") C.idText external body of
      Left err -> expectationFailure err
      Right doc -> do
        let source = D.render D.Compact doc
        source `shouldSatisfy` isInfixOf "scoped(_OuterSchema,"
        source `shouldSatisfy` isInfixOf "scoped(_LsHandledSchema0,"
        source `shouldSatisfy` isInfixOf "read(_LsHandledSchema1)"
  -- ref:DEC-total-definitions ref:DEC-native-property-frameworks
  mapM_ (\target -> it (target ++ " emits native abilities and keeps example recordings in the case scope") $ do
    input <- readFile "acceptance/beam-handler-context/context.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let source = concatMap artifactContent artifacts
            adapters = filter ((== "user") . ownership) artifacts
        source `shouldSatisfy` isInfixOf "lawspec_beam_effects:with_native_context"
        source `shouldSatisfy` isInfixOf "lawspec_beam_effects:recover_handler"
        source `shouldSatisfy` isInfixOf "lawspec_beam_effects:with_scope"
        source `shouldSatisfy` isInfixOf "_LsExampleSchema"
        length adapters `shouldBe` 1
        concatMap artifactContent adapters `shouldSatisfy` isInfixOf "counter_handler"
        case generatedFor target True input of
          Left errors -> expectationFailure (show errors)
          Right compact -> map adapterReference adapters `shouldBe`
            map adapterReference (filter ((== "user") . ownership) compact)) ["erlang","elixir","gleam"]
  -- ref:DEC-idiomatic-generated-types
  mapM_ (\target -> it (target ++ " emits a factory for an ability without adapters") $ do
    let source = "unit edge.abilities\nability Opaque is echo :: Int32 end\n"
    case generatedFor target False source of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let adapters = filter ((== "user") . ownership) artifacts
        length adapters `shouldBe` 1
        concatMap artifactContent adapters `shouldSatisfy` isInfixOf "opaque_handler"
        if target == "gleam" then concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "pub fn opaque_lawspec("
          else pure ()) ["erlang","elixir","gleam"]
  -- ref:DEC-idiomatic-generated-types
  it "diagnoses native ability constructor collisions before emitting Gleam" $ do
    let source = unlines ["unit sample", "ability Counter is read :: Int32 end",
          "handler counter for Counter is read is 0 end end"]
    case generatedFor "gleam" False source of
      Left errors -> show errors `shouldSatisfy` isInfixOf "handler constructors and operation functions collide"
      Right _ -> expectationFailure "colliding native constructors were accepted"
  -- ref:DEC-total-definitions ref:DEC-native-property-frameworks
  it "emits reusable checked definitions and PropEr generators from Core" $ do
    input <- readFile "examples/specs/total_functions.lawspec"
    case generated False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let files = map artifactPath artifacts
            contents = concatMap artifactContent artifacts
        files `shouldContain` ["src/lawspec_definitions.erl", "src/example_total_functions_definitions.erl"]
        contents `shouldSatisfy` isInfixOf "lawspec_beam_proper:forall"
        contents `shouldSatisfy` isInfixOf "lawspec_beam_schema:match"
        contents `shouldSatisfy` isInfixOf "andalso"
        filter ((== "user") . ownership) artifacts `shouldBe` []
  -- ref:DEC-adapter-ownership ref:DEC-readable-output-default
  it "keeps one readable adapter baseline across both layouts" $ do
    let source = "unit example.codec\nechoText :: Text -> Text\n"
    case (generated False source, generated True source) of
      (Right readable,Right compact) -> do
        let user = filter ((== "user") . ownership)
        map artifactPath (user readable) `shouldBe` ["src/example_codec.erl"]
        map adapterReference (user readable) `shouldBe` map adapterReference (user compact)
        map adapterReference (user readable) `shouldBe` map (Just . artifactContent) (user readable)
      failure -> expectationFailure (show failure)
  -- ref:DEC-idiomatic-generated-types
  it "emits tuple constructors and exported types for recursive data" $ do
    input <- readFile "examples/specs/data_types.lawspec"
    case generated False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let content = concat [artifactContent a | a <- artifacts, artifactPath a == "src/lawspec_data.erl"]
        content `shouldSatisfy` isInfixOf "-export_type("
        content `shouldSatisfy` isInfixOf "tree_leaf"
        content `shouldSatisfy` isInfixOf "lawspec_data:tree(_T0)"
  -- ref:DEC-idiomatic-generated-types
  it "rejects collisions after native name normalization" $ do
    generated False "unit example.names\nfooBar :: Int32 -> Int32\nfoo_bar :: Int32 -> Int32\n" `shouldSatisfy` isLeft
    generated False "unit lawspec.data\nf :: Int8 -> Int8\n" `shouldSatisfy` isLeft
  -- ref:DEC-incremental-compilation
  it "uses the same module and law identifiers in the test manifest" $ do
    unitTestPath "erlang" "example.httpClient" `shouldBe` "test/example_http_client_lawspec_tests.erl"
    unitTestNames "erlang" ["same", "same"] `shouldBe` ["law_same", "law_same_2"]
    unitTestNames "erlang" (replicate 2 (replicate 1000 'x')) `shouldBe`
      ["law_" ++ replicate 48 'x', "law_" ++ replicate 48 'x' ++ "_2"]
    unitTestPath "elixir" "example.httpClient" `shouldBe` "test/example_http_client_lawspec_test.exs"
    unitTestNames "elixir" ["same", "same"] `shouldBe` ["law_same", "law_same_2"]
    unitTestPath "gleam" "example.httpClient" `shouldBe` "test/example_http_client_lawspec_test.gleam"
  -- ref:DEC-native-property-frameworks ref:DEC-adapter-ownership
  it "emits Elixir adapters and ExUnit laws backed by native StreamData" $ do
    input <- readFile "examples/specs/scalar_adapters.lawspec"
    case (generatedFor "elixir" False input, generatedFor "elixir" True input) of
      (Right readable,Right compact) -> do
        let user = filter ((== "user") . ownership)
            files = map artifactPath readable
        map artifactPath (user readable) `shouldBe` ["lib/example_scalar_adapters.ex"]
        map adapterReference (user readable) `shouldBe` map adapterReference (user compact)
        mapM_ (\path -> files `shouldContain` [path]) ["test/support/lawspec_beam_stream_data.ex", "test/example_scalar_adapters_lawspec_test.exs"]
        files `shouldNotContain` ["test/lawspec_beam_proper.erl"]
        concatMap artifactContent (user readable) `shouldSatisfy` isInfixOf "defmodule Example.ScalarAdapters"
      failure -> expectationFailure (show failure)
  -- ref:DEC-idiomatic-generated-types ref:DEC-total-definitions
  it "gives Elixir callers struct data and checked production definitions" $ do
    input <- readFile "examples/specs/data_types.lawspec"
    case generatedFor "elixir" False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        mapM_ (\path -> map artifactPath artifacts `shouldContain` [path]) ["lib/lawspec/data/pair.ex", "lib/example_data_types_definitions.ex"]
        let body = concatMap artifactContent artifacts
        body `shouldSatisfy` isInfixOf "defstruct"
        body `shouldSatisfy` isInfixOf "Elixir.LawSpec.Data.Pair"
        body `shouldSatisfy` isInfixOf "@spec positive_pair("
  -- ref:DEC-idiomatic-generated-types ref:DEC-incremental-compilation
  it "relocates Elixir and Erlang sources without adding an extra lib directory" $ do
    let plan = compileCore 64 defaultGeneration [Source "elixir.lawspec" "unit example.echo\necho :: Text -> Text\n"] >>= planTesting
        generatedAt sourceDir testDir = plan >>= emitPlanWithOptions False "elixir" sourceDir testDir
    case (generatedAt Nothing Nothing, generatedAt (Just "generated/source") (Just "generated/tests")) of
      (Right standard, Right relocated) -> do
        let paths = map artifactPath
        mapM_ (\p -> paths standard `shouldContain` [p]) ["lib/example_echo.ex", "src/lawspec_data.erl"]
        mapM_ (\p -> paths relocated `shouldContain` [p]) ["generated/source/example_echo.ex", "generated/source/lawspec_data.erl"]
        paths standard `shouldNotContain` ["lib/src/lawspec_data.erl", "src/lib/example_echo.ex"]
      failure -> expectationFailure (show failure)
  -- ref:DEC-native-property-frameworks ref:DEC-adapter-ownership
  it "emits typed Gleam adapters and one native Gleeunit entry per case" $ do
    input <- readFile "examples/specs/scalar_adapters.lawspec"
    case (generatedFor "gleam" False input, generatedFor "gleam" True input) of
      (Right readable,Right compact) -> do
        let user = filter ((== "user") . ownership)
            files = map artifactPath readable
        map artifactPath (user readable) `shouldBe` ["src/example/scalar_adapters.gleam"]
        map adapterReference (user readable) `shouldBe` map adapterReference (user compact)
        mapM_ (\p -> files `shouldContain` [p]) ["src/lawspec/types.gleam", "test-support/src/lawspec_beam_qcheck.erl", "test-support/src/lawspec_beam_coverage.erl", "test-support/src/example_scalar_adapters_lawspec_cases.erl", "test/example_scalar_adapters_lawspec_test.gleam"]
        -- Build configuration belongs to init/the adopter, before doctor and
        -- dependency setup. Generation must neither claim nor remove it.
        files `shouldNotContain` ["test-support/gleam.toml", "test/lawspec_beam_qcheck.erl", "test/example_scalar_adapters_lawspec_cases.erl"]
        concatMap artifactContent (user readable) `shouldSatisfy` isInfixOf "types.Optional(types.Nullable(Int))"
        let tests = concat [artifactContent a | a <- readable, artifactPath a == "test/example_scalar_adapters_lawspec_test.gleam"]
        tests `shouldSatisfy` isInfixOf "_test() -> Nil"
      failure -> expectationFailure (show failure)
  -- ref:DEC-idiomatic-generated-types ref:DEC-total-definitions
  it "emits Gleam algebraic data and checked production FFI wrappers" $ do
    input <- readFile "examples/specs/data_types.lawspec"
    case generatedFor "gleam" False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let body = concat [artifactContent a | a <- artifacts, artifactPath a == "src/lawspec/data.gleam"]
        body `shouldSatisfy` isInfixOf "pub type Pair(a0, a1)"
        body `shouldSatisfy` isInfixOf "TreeBranch(children: List(Tree(a0)))"
        mapM_ (\p -> map artifactPath artifacts `shouldContain` [p])
          ["src/example/data_types/definitions.gleam", "src/example_data_types_definitions_ffi.erl"]
  -- ref:DEC-native-bindings-typed-identity
  it "rejects a Gleam layout that would change its compiled module identities" $ do
    let plan = compileCore 64 defaultGeneration [Source "gleam.lawspec" "unit example.echo\necho :: Text -> Text\n"] >>= planTesting
    (plan >>= emitPlanWithOptions False "gleam" (Just "src/generated") Nothing) `shouldSatisfy` isLeft
  -- ref:DEC-indexed-families-as-evidence ref:DEC-gadts-and-index-arithmetic
  it "carries directed indices and existential witnesses into every native framework" $ do
    indexed <- readFile "examples/specs/indexed_arithmetic.lawspec"
    gadt <- readFile "examples/specs/gadt_expressions.lawspec"
    mapM_ (\target -> mapM_ (\source -> case generatedFor target False source of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "lawspec_beam_index"
        concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "witness_instances") [indexed,gadt])
      ["erlang","elixir","gleam"]
  -- ref:DEC-typed-core-boundary
  it "emits checked typed failures through native and public definition boundaries" $ do
    input <- readFile "acceptance/beam-failures/failures.lawspec"
    mapM_ (\target -> case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        map artifactPath artifacts `shouldContain` ["src/lawspec_beam_effects.erl"]
        let definitions = concat [artifactContent a | a <- artifacts, artifactPath a == "src/lawspec_definitions.erl"]
            tests = concat [artifactContent a | a <- artifacts, artifactPlacement a == "test"]
        definitions `shouldSatisfy` isInfixOf "lawspec_beam_effects:raise_failure"
        definitions `shouldSatisfy` isInfixOf "lawspec_beam_effects:native_failures"
        tests `shouldSatisfy` isInfixOf "lawspec_beam_effects:attempt") ["erlang","elixir","gleam"]
  -- ref:REQ-law-primitives ref:DEC-typed-core-boundary
  it "permits the compiler's matcher definitions in the reserved Gleam namespace" $ do
    input <- readFile "examples/specs/matchers.lawspec"
    case generatedFor "gleam" False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> map artifactPath artifacts `shouldContain` ["src/lawspec/matchers/definitions.gleam"]
  -- ref:DEC-never-pass-vacuously
  -- ref:REQ-law-primitives
  mapM_ (\target -> it (target ++ " brackets examples, boundaries and native property attempts with resources") $ do
    let input = unlines
          [ "unit example.resources", "handle Store", "openStore :: Unit -> Store"
          , "closeStore :: Store -> Unit", "empty :: Store -> Bool", "write :: Store -> Int32 -> Bool"
          , "resource Store is acquire is openStore unitValue end release s is closeStore s end end"
          , "law `fresh` for first :: Store, second :: Store is"
          , " definition is `for all` (n :: Int32) . empty first and write second n end"
          , " example `still open` is n = 1 expect empty first end", "end" ]
    case compileCore 64 defaultGeneration [Source "resources.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.Pretty 100) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["_LsResource0", "_LsResource1", "lawspec_beam_resources:with_resource", "example 0: still open", "property", "boundary 0"]
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-never-pass-vacuously ref:REQ-harness-units
  it "emits shared resource leases with their checked acquire, reset and release clauses" $ do
    input <- readFile "examples/specs/resources.lawspec"
    case compileCore 64 defaultGeneration [Source "resources.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit "erlang" (D.Pretty 100) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "lawspec_beam_resources:with_shared"
          map artifactPath artifacts `shouldContain` ["test/lawspec_generated_tests.erl"]
          let unit = concat [artifactContent a | a <- artifacts, artifactPath a == "test/example_resources_lawspec_tests.erl"]
          unit `shouldSatisfy` isInfixOf "suite/0"
          unit `shouldSatisfy` isInfixOf "_cases/0"
          unit `shouldSatisfy` isInfixOf "lawspec_beam_test_run:fixture"
  -- ref:DEC-never-pass-vacuously ref:REQ-harness-units
  mapM_ (\target -> it (target ++ " emits dedicated resource owners and cancellation support") $ do
    input <- readFile "examples/specs/resources.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let body = concatMap artifactContent artifacts
        mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
          ["lawspec_beam_resources:with_resource", "lawspec_beam_resources:with_shared",
           "lawspec_beam_tasks:open()", "resource_cleanup_timeout"]
    ) ["erlang", "elixir", "gleam"]
  -- ref:DEC-never-pass-vacuously ref:REQ-harness-units
  mapM_ (\target -> it (target ++ " enforces per-test timeouts inside the native runner allowance") $ do
    let input = unlines
          [ "unit example.timeout", "pause :: Unit -> Bool"
          , "law `ends` is definition is pause unitValue end end"
          , "harness example.timeout.testing for example.timeout is"
          , " for law `ends`", "  timeout 10 ms", "end" ]
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let body = concatMap artifactContent artifacts
        body `shouldSatisfy` isInfixOf "timeout => 10"
        body `shouldSatisfy` isInfixOf "lawspec_beam_resources:start(CleanupTimeout)"
    ) ["erlang", "elixir", "gleam"]
  -- ref:REQ-harness-units ref:DEC-native-property-frameworks
  mapM_ (\(target,path) -> it (target ++ " publicly compiles completed harness controls: " ++ path) $ do
    input <- readFile path
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        artifacts `shouldSatisfy` (not . null)
        concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "lawspec_beam_harness"
    ) [(target,path) | target <- ["erlang", "elixir", "gleam"], path <-
        ["acceptance/beam-strategies/strategies.lawspec", "acceptance/beam-adequacy/adequacy.lawspec",
         "acceptance/beam-target/target.lawspec", "acceptance/beam-repetition/repetition.lawspec",
         "acceptance/beam-selection/b.lawspec", "acceptance/beam-benchmarks/benchmarks.lawspec",
         "examples/specs/scheduling_order.lawspec"]]
  -- ref:REQ-harness-units ref:DEC-native-property-frameworks
  mapM_ (\(target,bits,compact) -> it (target ++ " composes native strategy draws " ++ show (bits,compact)) $ do
    input <- readFile "acceptance/beam-strategies/strategies.lawspec"
    case compileCore bits defaultGeneration [Source "strategies.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            [":such_that(", ":frequency(", "lists:nth(", "lawspec_beam_generators:check_drawn",
             "_LsDraw", "_LsKeep", "340282366920938463463374607431768211456",
             "examples are outside the strategy", "boundary"]
          body `shouldSatisfy` (not . isInfixOf "<<\"neverDrawn\"/utf8>>")
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-never-pass-vacuously
  mapM_ (\(target,bits,compact) -> it (target ++ " emits native coverage accounting " ++ show (bits,compact)) $ do
    input <- readFile "acceptance/beam-adequacy/adequacy.lawspec"
    case compileCore bits defaultGeneration [Source "adequacy.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_harness:run", "lawspec_beam_harness:sample", "finite observations statistics",
             "examples do not count", "lawspec_definitions:", "above its prefix"]
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " groups known failures and omits skipped law bodies " ++ show (bits,compact)) $ do
    input <- readFile "acceptance/beam-status/status.lawspec"
    case compileCore bits defaultGeneration [Source "status.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_harness:known_failing", "known property failure known failing", "skipped completely skipped"]
          body `shouldSatisfy` (not . isInfixOf "law_skipped_completely_body")
          body `shouldSatisfy` (not . isInfixOf "also skipped")
          if target == "elixir" then body `shouldSatisfy` isInfixOf "@tag skip: reason"
            else body `shouldSatisfy` isInfixOf "lawspec_beam_harness:erlang_cases"
          if target == "gleam" then do
            body `shouldSatisfy` isInfixOf "__skipped_test_"
            body `shouldSatisfy` (not . isInfixOf "law_skipped_completely__case_0_test")
            else pure ()
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " emits exact native law selection identities " ++ show (bits,compact)) $ do
    sources <- mapM (\path -> Source path <$> readFile path)
      ["acceptance/beam-selection/a.lawspec", "acceptance/beam-selection/b.lawspec"]
    case compileCore bits defaultGeneration sources of
      Left errors -> expectationFailure (show errors)
      Right program -> case planTesting program of
        Left errors -> expectationFailure (show errors)
        Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
          Left message -> expectationFailure message
          Right artifacts -> do
            let body = concatMap artifactContent artifacts
                entries = TestManifest.testManifest target Nothing program
            length entries `shouldBe` 7
            mapM_ (\entry -> body `shouldSatisfy` isInfixOf
              (TestManifest.entryUnit entry ++ "::" ++ TestManifest.entryName entry)) entries
            body `shouldSatisfy` isInfixOf (if target == "elixir" then "@tag lawspec_identity" else "lawspec_beam_test_run:select")
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " registers every model and scenario with its native test identity " ++ show (bits,compact)) $ do
    sources <- mapM (\path -> Source path <$> readFile path)
      ["examples/specs/models.lawspec", "acceptance/beam-actor-api/actor_api.lawspec"]
    case compileCore bits defaultGeneration sources of
      Left errors -> expectationFailure (show errors)
      Right program -> case planTesting program of
        Left errors -> expectationFailure (show errors)
        Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
          Left message -> expectationFailure message
          Right artifacts -> do
            let body = concatMap artifactContent artifacts
                entries = TestManifest.testManifest target Nothing program
                identities = map TestManifest.entryLaw entries
                models = [entry | entry <- entries, "::model::" `isInfixOf` C.idText (TestManifest.entryLaw entry)]
                modelOnly = [entry | entry <- entries, TestManifest.entryUnit entry == "example.models"]
            -- Model contracts also contribute four ordinary laws.
            length entries `shouldBe` 16
            length models `shouldBe` 9
            length (nub identities) `shouldBe` length entries
            map TestManifest.entryIndex modelOnly `shouldBe` [0..10]
            mapM_ (\name -> map TestManifest.entryName modelOnly `shouldContain` [name])
              ["model_stack__sequential", "model_counter__parallel", "model_counter__scenario_a_reply_is_delegated"]
            mapM_ (\entry -> do
              map artifactPath artifacts `shouldContain` [TestManifest.entryFile entry]
              body `shouldSatisfy` isInfixOf (TestManifest.entryUnit entry ++ "::" ++ TestManifest.entryName entry)) entries
            all TestManifest.entryCallsAdapters models `shouldBe` True
            map TestManifest.entryCallsAdapters [entry | entry <- entries, TestManifest.entryName entry == "supervision"]
              `shouldBe` [False]
            case emitPlanWithFormat compact target plan of
              Left errors -> expectationFailure (show errors)
              Right generated -> do
                let paths = map artifactPath generated
                length (nub paths) `shouldBe` length paths
                mapM_ (\entry -> paths `shouldContain` [TestManifest.entryFile entry]) entries
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-test-manifest ref:DEC-never-pass-vacuously
  it "keeps model names, scenario names and long labels distinct after normalization" $ do
    input <- readFile "examples/specs/models.lawspec"
    case compileCore 64 defaultGeneration [Source "models.lawspec" input] of
      Left errors -> expectationFailure (show errors)
      Right program -> case [(u,m,s) | u <- C.programUnits program, C.idText (C.unitId u) == "example.models",
          m <- C.unitMachines u, Machine.machineName m == "counter", s <- take 1 (Machine.machineScenarios m)] of
        [(unit,machine,scenario)] -> do
          let named name title = machine {Machine.machineName = name,
                Machine.machineScenarios = [scenario {Program.programTitle = title}]}
              checks = ModelChecks.checks (unit {C.unitMachines =
                [named "a" "x sequential", named "a_scenario_x" "same", named "b" "same",
                 named (replicate 1000 'x') (replicate 1000 'y'),
                 named (replicate 1000 'x' ++ "z") (replicate 1000 'y' ++ "z")]})
              names = map ModelChecks.checkName checks
          length (nub names) `shouldBe` length names
          length (nub (map ModelChecks.checkIdentity checks)) `shouldBe` length checks
          length (nub (map ModelChecks.checkLabel checks)) `shouldBe` length checks
          all ((< 160) . length) names `shouldBe` True
          names `shouldContain` ["model_a__scenario_x_sequential", "model_a_scenario_x__sequential"]
        _ -> expectationFailure "missing model fixture unit"
  -- ref:REQ-test-manifest ref:DEC-incremental-compilation
  it "invalidates model evidence when a checked callback or an imported session changes" $ do
    input <- readFile "examples/specs/models.lawspec"
    case compileCore 64 defaultGeneration [Source "models.lawspec" input] of
      Left errors -> expectationFailure (show errors)
      Right program -> do
        let keys p = [TestManifest.entryKey entry | entry <- TestManifest.testManifest "erlang" Nothing p,
              "::model::" `isInfixOf` C.idText (TestManifest.entryLaw entry)]
            changedDefinitions = program {C.programUnits = [u {C.unitDefinitions = []} | u <- C.programUnits program]}
            movedSessions = program {C.programUnits = [u {C.unitSessions = []} | u <- C.programUnits program]}
        length (keys program) `shouldBe` 7
        and (zipWith (/=) (keys program) (keys changedDefinitions)) `shouldBe` True
        and (zipWith (/=) (keys program) (keys movedSessions)) `shouldBe` True
        map TestManifest.entryFile (TestManifest.testManifest "erlang" (Just "checks") program)
          `shouldBe` replicate 11 "checks/example_models_lawspec_tests.erl"
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " emits selectable benchmarks including units without laws " ++ show (bits,compact)) $ do
    sources <- mapM (\path -> Source path <$> readFile path)
      ["acceptance/beam-benchmarks/benchmarks.lawspec", "acceptance/beam-benchmarks/only.lawspec"]
    case compileCore bits defaultGeneration sources of
      Left errors -> expectationFailure (show errors)
      Right program -> case planTesting program of
        Left errors -> expectationFailure (show errors)
        Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
          Left message -> expectationFailure message
          Right artifacts -> do
            let body = concatMap artifactContent artifacts
                entries = TestManifest.benchmarkManifest target Nothing program
            length entries `shouldBe` 8
            mapM_ (\entry -> do
              map artifactPath artifacts `shouldContain` [TestManifest.benchmarkFile entry]
              body `shouldSatisfy` isInfixOf (TestManifest.benchmarkTest entry ++ "_test_")) entries
            mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
              ["lawspec_beam_harness:benchmark", "benchmark_same_name_2", "benchmark_law_2", "_production", "false is a value"]
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " retains native cases under seeded and parallel scheduling " ++ show (bits,compact)) $ do
    sources <- mapM (\path -> Source path <$> readFile path)
      ["examples/specs/scheduling_order.lawspec", "examples/specs/scheduling_overlap.lawspec"]
    case compileCore bits defaultGeneration sources >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["the first pause ends", "the sixth pause ends", "the first nap ends", "the third nap ends"]
          if target == "elixir" then
            mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
              ["LawSpec.Beam.ExUnitSchedule.setup", "LawSpec.Beam.ExUnitSchedule.await", "@tag lawspec_case:", "@tag lawspec_order:"]
          else body `shouldSatisfy` isInfixOf "lawspec_beam_schedule:eunit"
          if target == "gleam" then body `shouldSatisfy` isInfixOf "pub fn lawspec_suite()"
            else pure ()
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " repeats complete native checks and records retries " ++ show (bits,compact)) $ do
    input <- readFile "acceptance/beam-repetition/repetition.lawspec"
    case compileCore bits defaultGeneration [Source "repetition.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_harness:run", "repeat => 3", "repeat => 2", "retries => 1", "observed => false",
             "observed => true", "repeated example", "repeated finite cases boundary", "repeated search search"]
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\target -> it (target ++ " includes replay runtime dependencies for an ordinary property") $ do
    let input = "unit example.replay\nf :: Int32 -> Int32\nlaw `identity` is definition is `for all` (n :: Int32) . f n = n end end\n"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let paths = map artifactPath artifacts
            support = case target of "erlang" -> "test/"; "elixir" -> "test/support/"; _ -> "test-support/src/"
        mapM_ (\name -> paths `shouldContain` [support ++ "lawspec_beam_" ++ name ++ ".erl"])
          ["search", "random"]
        paths `shouldContain` ["src/lawspec_beam_values.erl"]
        length (filter (isInfixOf "lawspec_beam_values.erl") paths) `shouldBe` 1
        if target == "elixir" then do
          paths `shouldContain` [support ++ "lawspec_beam_exunit_schedule.ex"]
          length (filter (isInfixOf "lawspec_beam_tasks.erl") paths) `shouldBe` 1
          else pure ()
    ) ["erlang", "elixir", "gleam"]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " replays saved native inputs with current refinements " ++ show (bits,compact)) $ do
    let input = unlines ["unit example.replay", "f :: Integer -> Integer -> Integer",
          "law `dependent replay` is definition is `for all` (n :: Integer) (m :: Integer where m > n) . f n m = m end end"]
    case compileCore bits defaultGeneration [Source "replay.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_search:replay", "lawspec_beam_search:guard", "example.replay::dependent replay", "false -> none"]
          body `shouldSatisfy` (not . isInfixOf "lawspec_beam_search:climb")
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units ref:DEC-portable-seeded-generation
  mapM_ (\(target,bits,compact) -> it (target ++ " emits targeted search with checked refinements " ++ show (bits,compact)) $ do
    input <- readFile "acceptance/beam-target/target.lawspec"
    case compileCore bits defaultGeneration [Source "target.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit target (D.selectLayout compact (D.Pretty 100)) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          mapM_ (\part -> body `shouldSatisfy` isInfixOf part)
            ["lawspec_beam_search:climb", "lawspec_beam_harness:sample", "interior maximum search",
             "dependent maximum search", "false -> none", "{score,", "(int Integer 340282366920938463463374607431768211456"]
    ) [(target,bits,compact) | target <- ["erlang","elixir","gleam"], bits <- [32,64], compact <- [False,True]]
  -- ref:REQ-harness-units
  it "observes floating-point targets without inventing a wire descriptor" $ do
    let input = unlines ["unit example.floatingTarget", "f :: Float64 -> Float64",
          "law `floating score` is definition is `for all` (n :: Float64) . f n = n end end",
          "harness example.floatingTarget.testing for example.floatingTarget is",
          " for law `floating score`", "  target maximize n", "end"]
    case compileCore 64 defaultGeneration [Source "target.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit "erlang" (D.Pretty 100) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> do
          let body = concatMap artifactContent artifacts
          body `shouldSatisfy` isInfixOf "lawspec_beam_harness:sample"
          body `shouldSatisfy` (not . isInfixOf "lawspec_beam_search:climb")
          body `shouldSatisfy` (not . isInfixOf "lawspec_beam_search:guard")
          body `shouldSatisfy` (not . isInfixOf "lawspec_beam_search:replay")
  -- A bind may draw a type unrelated to the law's own inputs. Its native
  -- generator still needs a witness for a structural minimum beyond 64.
  -- ref:REQ-harness-units ref:DEC-structural-size-budget
  it "plans structural witnesses for a strategy's intermediate any type" $ do
    let input = unlines (["unit example.deepStrategy"] ++
          ["type D" ++ show i ++ " is C" ++ show i ++ " next :: " ++
            (if i == 65 then "Bool" else "D" ++ show (i + 1)) ++ " end" | i <- [0::Int ..65]] ++
          [ "law `identity` is definition is `for all` (n :: Int32) . n = n end end"
          , "harness example.deepStrategy.testing for example.deepStrategy is"
          , "  strategy value :: Int32 is bind deep :: D0 from any D0 in one of 0 end"
          , "  for law `identity`", "    use value for n", "end" ])
    case compileCore 64 defaultGeneration [Source "deep.lawspec" input] >>= planTesting of
      Left errors -> expectationFailure (show errors)
      Right plan -> case Properties.emit "erlang" (D.Pretty 100) emptyBindingPlan plan of
        Left message -> expectationFailure message
        Right artifacts -> concatMap artifactContent artifacts `shouldSatisfy` isInfixOf "ls_data"
  -- ref:DEC-async-native-tasks ref:DEC-native-bindings-typed-identity
  mapM_ (\target -> it (target ++ " awaits async native calls before checking their result") $ do
    input <- readFile "examples/specs/async_fetch.lawspec"
    case generatedFor target False input of
      Left errors -> expectationFailure (show errors)
      Right artifacts -> do
        let definitions = concat [artifactContent a | a <- artifacts, artifactPath a == "src/lawspec_definitions.erl"]
            adapters = concat [artifactContent a | a <- artifacts, ownership a == "user"]
        definitions `shouldSatisfy` isInfixOf "lawspec_beam_runtime:async_call"
        definitions `shouldSatisfy` isInfixOf "lawspec_beam_schema:from_native"
        adapters `shouldSatisfy` (not . isInfixOf "_Handler")
        adapters `shouldSatisfy` (not . isInfixOf "_handler")) ["erlang", "elixir", "gleam"]
