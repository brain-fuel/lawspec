-- | BEAM generation consumes the same checked plan and retains native source
-- ownership and every planned case. ref:DEC-tests-cite-requirements
module BeamSpec (test_beamCodeUsesCheckedCoreAndNativeFrameworks) where

import Test.Hspec
import Data.List (isInfixOf)
import Data.Either (isLeft)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlanWithFormat, emitPlanWithOptions)
import LawSpec.TestManifest (unitTestPath)
import LawSpec.TestNames (unitTestNames)

generated :: Bool -> String -> Either [Diagnostic] [Artifact]
generated = generatedFor "erlang"

generatedFor :: String -> Bool -> String -> Either [Diagnostic] [Artifact]
generatedFor target compact text = compileCore 64 defaultGeneration [Source "beam.lawspec" text]
  >>= planTesting >>= emitPlanWithFormat compact target

test_beamCodeUsesCheckedCoreAndNativeFrameworks :: Spec
test_beamCodeUsesCheckedCoreAndNativeFrameworks = describe "BEAM generation" $ do
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
  -- ref:DEC-never-pass-vacuously
  it "refuses an execution plane before it can silently omit its behavior" $ do
    input <- readFile "examples/specs/abilities.lawspec"
    generated False input `shouldSatisfy` isLeft
