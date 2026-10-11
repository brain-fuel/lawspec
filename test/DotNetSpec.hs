-- | F# and C# generation: the F# project and its runtime, C# over a generated
-- F# model, native bindings, and the names lawspec test selects tests by.
-- ref:DEC-fsharp-runtime-from-scratch ref:DEC-csharp-over-fsharp ref:DEC-tests-cite-requirements
module DotNetSpec (test_dotnetTargetsShareOneRuntime) where

import Test.Hspec
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import qualified Data.Text as T
import LawSpec.Api (dispatch)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlanWithFormat)
import LawSpec.TestManifest (unitTestPath)
import LawSpec.TestNames (unitTestNames)

generated :: String -> Bool -> String -> Either [Diagnostic] [Artifact]
generated target compact text = compileCore 64 defaultGeneration [Source "dotnet.lawspec" text]
  >>= planTesting >>= emitPlanWithFormat compact target

paths :: Either [Diagnostic] [Artifact] -> [FilePath]
paths = either (const []) (map artifactPath)

contentOf :: FilePath -> Either [Diagnostic] [Artifact] -> String
contentOf path = either (const "") (\as -> concat [artifactContent a | a <- as, artifactPath a == path])

test_dotnetTargetsShareOneRuntime :: Spec
test_dotnetTargetsShareOneRuntime = describe ".NET generation" $ do
  let sample = unlines
        [ "unit example.sample"
        , "type Pair is Pair left :: Int32 right :: Text end"
        , "swap :: Pair -> Pair"
        , "finish :: Unit -> Unit"
        , "law `swap twice` is definition is `for all` (p :: Pair) . swap (swap p) = p end end" ]
  it "writes an F# project whose props list the sources in compilation order" $ do
    let result = generated "fsharp" False sample
    mapM_ (\path -> paths result `shouldContain` [path]) ["src/LawSpec.Sources.props", "tests/LawSpec.Tests.props", "src/Example/Sample.fs",
      "lawspec/LawSpec.Runtime/LawSpec.Runtime.fsproj", "lawspec/LawSpec.Testing/LawSpec.Testing.fsproj"]
    let props = contentOf "src/LawSpec.Sources.props" result
    props `shouldSatisfy` isInfixOf "Native/Types/**/*.fs"
    (length (takeWhile (not . isInfixOf "LawSpec/Data.fs") (lines props)) <
      length (takeWhile (not . isInfixOf "Example/Sample.fs") (lines props))) `shouldBe` True
    contentOf "src/Example/Sample.fs" result `shouldSatisfy` isInfixOf "failwith \"not implemented: example.sample::swap\""
  it "runs C# over a generated F# model project" $ do
    let result = generated "csharp" False sample
    mapM_ (\path -> paths result `shouldContain` [path]) ["lawspec/LawSpec.Model/LawSpec.Model.fsproj", "lawspec/LawSpec.Model/Data.fs",
      "src/Example/Sample.cs", "src/LawSpec/Generated/ExampleSample.cs"]
    contentOf "src/LawSpec.Sources.props" result `shouldSatisfy` isInfixOf "LawSpec.Model.fsproj"
    let adapter = contentOf "src/Example/Sample.cs" result
    adapter `shouldSatisfy` isInfixOf "public static LawSpec.Data.Pair Swap(LawSpec.Data.Pair value0)"
    -- C# adapters take no Unit and return void for it.
    adapter `shouldSatisfy` isInfixOf "public static void Finish()"
    contentOf "lawspec/LawSpec.Runtime/CSharp.fs" result `shouldSatisfy` isInfixOf "namespace LawSpec.CSharp"
  it "keeps the same files in the compact layout" $
    mapM_ (\target -> paths (generated target True sample) `shouldBe` paths (generated target False sample)) ["fsharp", "csharp"]
  it "names tests as lawspec test selects them" $ do
    unitTestNames "fsharp" ["swap twice"] `shouldBe` ["lawSwapTwice"]
    unitTestNames "csharp" ["swap twice"] `shouldBe` ["LawSwapTwice"]
    unitTestPath "fsharp" "example.scalar_adapters" `shouldBe` "tests/LawSpec/ExampleScalarAdapters.fs"
    unitTestPath "csharp" "example.sample" `shouldBe` "tests/LawSpec/ExampleSample.cs"
    contentOf "tests/LawSpec/ExampleSample.cs" (generated "csharp" False sample) `shouldSatisfy` isInfixOf "public void LawSwapTwice_Property()"
  -- ref:DEC-native-bindings-typed-identity
  describe "native bindings" $ do
    let field key (Object value) = KM.lookup key value
        field _ _ = Nothing
        codes response = case field "diagnostics" response of
          Just (Array values) -> [code | Just code <- map (field "code") (toList values)]
          _ -> []
        files response = case field "files" response of
          Just (Array values) -> toList values
          _ -> []
        content file = case field "content" file of Just (String value) -> T.unpack value; _ -> ""
        request target source native = either error id (eitherDecode (dispatch (encode (object
          ["schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String), "target" .= (target :: String),
           "minify" .= False, "sources" .= [Source "binding" source], "nativeBindings" .= (native :: Value)]))))
    it "binds F# types, functions, handlers and exceptions" $ do
      source <- readFile "examples/specs/handler_bindings.lawspec"
      binding <- either error id . eitherDecode <$> BL.readFile "acceptance/handlerbindings/fsharp/bindings.json"
      let result = request "fsharp" source binding
      codes result `shouldBe` []
      concat [content f | f <- files result, field "path" f == Just (String "src/LawSpec/Data.fs")]
        `shouldSatisfy` isInfixOf "type Money = Till.Cash"
      concat [content f | f <- files result, field "path" f == Just (String "src/LawSpec/Generated/ExampleTill.fs")]
        `shouldSatisfy` isInfixOf "Effects.mapException<Till.CardDeclined>"
    it "refuses C# type bindings, which a C# program cannot give the F# model" $ do
      source <- readFile "examples/specs/handler_bindings.lawspec"
      binding <- either error id . eitherDecode <$> BL.readFile "acceptance/handlerbindings/fsharp/bindings.json"
      codes (request "csharp" source binding) `shouldBe` [String "native-binding"]
    it "binds C# functions, handlers and generators without types" $ do
      source <- readFile "examples/specs/payments.lawspec"
      config <- either error id . eitherDecode <$> BL.readFile "examples/native-payments/csharp/lawspec.json"
      let native = case config of
            Object o | Just (Array ts) <- KM.lookup "targets" o, Object t : _ <- toList ts, Just n <- KM.lookup "nativeBindings" t -> n
            _ -> Null
          result = request "csharp" source native
          generators = concat [content f | f <- files result, field "path" f == Just (String "tests/LawSpec/NativeGenerators.cs")]
      codes result `shouldBe` []
      generators `shouldSatisfy` isInfixOf "Domain.PaymentGenerators.Prices()"
      [p | f <- files result, Just (String p) <- [field "path" f], "src/Example/" `isPrefixOf` T.unpack p, ".cs" `isSuffixOf` T.unpack p]
        `shouldBe` []
