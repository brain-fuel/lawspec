-- | BEAM generation consumes the same checked plan and retains native source
-- ownership and every planned case. ref:DEC-tests-cite-requirements
module BeamSpec (test_beamCodeUsesCheckedCoreAndNativeFrameworks) where

import Test.Hspec
import Data.List (isInfixOf)
import Data.Either (isLeft)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (planTesting, Plan(..), PlannedUnit(..))
import LawSpec.CoreEmit (emitPlanWithFormat, emitPlanWithOptions)
import LawSpec.TestManifest (unitTestPath)
import LawSpec.TestNames (unitTestNames)
import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamActors as Actors
import qualified LawSpec.BeamModels as Models
import LawSpec.Scaffold (scaffoldFilesWith)

generated :: Bool -> String -> Either [Diagnostic] [Artifact]
generated = generatedFor "erlang"

generatedFor :: String -> Bool -> String -> Either [Diagnostic] [Artifact]
generatedFor target compact text = compileCore 64 defaultGeneration [Source "beam.lawspec" text]
  >>= planTesting >>= emitPlanWithFormat compact target

test_beamCodeUsesCheckedCoreAndNativeFrameworks :: Spec
test_beamCodeUsesCheckedCoreAndNativeFrameworks = describe "BEAM generation" $ do
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
          case target of
            "elixir" -> body `shouldSatisfy` isInfixOf "use ExUnit.Case"
            "gleam" -> body `shouldSatisfy` isInfixOf "model_counter_parallel_test() -> Nil"
            _ -> body `shouldSatisfy` isInfixOf "_test_()"
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
             "lawspec_beam_actors:start_link", "otp_child_spec", "tell_deposit", "handlers := []"]
          body `shouldSatisfy` (not . isInfixOf "proper:")
          case target of
            "elixir" -> paths `shouldContain` ["lib/lawspec/actors/example/actors/account_actor.ex"]
            "gleam" -> paths `shouldContain` ["src/lawspec/actors/example/actors/account_actor.gleam"]
            _ -> pure ()
    ) ["erlang", "elixir", "gleam"]
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
        mapM_ (\p -> files `shouldContain` [p]) ["src/lawspec/types.gleam", "test-support/gleam.toml", "test-support/src/lawspec_beam_qcheck.erl", "test-support/src/example_scalar_adapters_lawspec_cases.erl", "test/example_scalar_adapters_lawspec_test.gleam"]
        files `shouldNotContain` ["test/lawspec_beam_qcheck.erl", "test/example_scalar_adapters_lawspec_cases.erl"]
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
  -- ref:DEC-never-pass-vacuously
  it "refuses an execution plane before it can silently omit its behavior" $ do
    input <- readFile "examples/specs/resources.lawspec"
    case generated False input of
      Left errors -> show errors `shouldSatisfy` isInfixOf "resources and harness"
      Right _ -> expectationFailure "an unconnected execution plane was accepted"
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
