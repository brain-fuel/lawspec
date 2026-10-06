-- | Compiler API contracts checked at the JSON boundary that core.wasm exports.
-- These assertions inspect only request/response JSON, so they run in Haskell;
-- the npm tests keep what needs Node: WASM hosting, files and the CLI.
module ApiContractSpec (test_compilerApiAnswersEveryRequestByItsDocumentedContract) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Vector as V
import Test.Hspec
import LawSpec.Api (dispatch)

call :: [(K.Key, Value)] -> Value
call fields = fromMaybe (error "invalid API response") (decode (dispatch (encode (object fields))))

field :: String -> Value -> Value
field name (Object o) = fromMaybe Null (KM.lookup (K.fromString name) o)
field _ _ = Null

text :: Value -> String
text (String s) = T.unpack s
text _ = ""

list :: Value -> [Value]
list (Array a) = V.toList a
list _ = []

files :: Value -> [Value]
files = list . field "files"

fileWhere :: (String -> Bool) -> Value -> Value
fileWhere wanted result = case [f | f <- files result, wanted (text (field "path" f))] of
  f : _ -> f
  [] -> error "expected generated file"

content :: Value -> String
content = text . field "content"

diagnostics :: Value -> [Value]
diagnostics = list . field "diagnostics"

firstDiagnostic :: Value -> (String, String)
firstDiagnostic result = case diagnostics result of
  d : _ -> (text (field "code" d), text (field "message" d))
  [] -> ("", "")

-- | A regular expression /a.*b/ without newlines: the parts occur in order on one line.
lineMatches :: [String] -> String -> Bool
lineMatches parts = any (inOrder parts) . lines
  where
    inOrder [] _ = True
    inOrder (p : ps) line = case breakOn p line of
      Just rest -> inOrder ps rest
      Nothing -> False
    breakOn needle haystack
      | needle `isPrefixOfS` haystack = Just (drop (length needle) haystack)
      | null haystack = Nothing
      | otherwise = breakOn needle (tail haystack)
    isPrefixOfS a b = take (length a) b == a

source :: String -> String -> Value
source path body = object ["path" .= path, "content" .= body]

rustSource :: Value
rustSource = source "rust.lawspec" $ unlines
  [ "unit rust_example"
  , "successor :: Int8 -> Integer"
  , "law `promotes` is"
  , " definition is `for all` (x :: Int8) . successor x = x + 1 end"
  , " example `maximum` is x = 127 expect successor x = 128 end"
  , "end" ]

-- | The npm package, the CLI and the documentation site all reach the compiler
-- only through the JSON requests core.wasm exports, so a request that answers
-- differently from its documented contract breaks every client at once.
-- ref:DEC-wasm-distribution ref:REQ-compiler-api-contract
test_compilerApiAnswersEveryRequestByItsDocumentedContract :: Spec
test_compilerApiAnswersEveryRequestByItsDocumentedContract = describe "compiler API contracts" $ do
  describe "Rust" $ do
    it "owns adapters and separates the numeric runtime from Proptest helpers" $ do
      let result = call ["method" .= ("planGeneration" :: String), "target" .= ("rust" :: String), "sources" .= [rustSource]]
      diagnostics result `shouldBe` []
      field "schemaVersion" result `shouldBe` Number 3
      text (field "kind" (field "origin" (head (list (field "declarations" (head (list (field "units" result)))))))) `shouldBe` "source"
      let adapter = head [f | f <- files result, text (field "ownership" f) == "user"]
      text (field "path" adapter) `shouldBe` "src/rust_example.rs"
      content adapter `shouldSatisfy` lineMatches ["value0: i8", "ls::Integer"]
      let runtime = fileWhere (== "src/lawspec_runtime.rs") result
      text (field "placement" runtime) `shouldBe` "source"
      text (field "ownership" runtime) `shouldBe` "generated"
      content runtime `shouldNotSatisfy` isInfixOf "use proptest"
      content (fileWhere ("lawspec_strategies.rs" `isSuffixOf`) result) `shouldSatisfy` isInfixOf "proptest"
      content (fileWhere ("lawspec_modules.rs" `isSuffixOf`) result) `shouldSatisfy` isInfixOf "pub mod rust_example"
      let tests = content (fileWhere (== "tests/rust_example_lawspec.rs") result)
      tests `shouldSatisfy` isInfixOf "128"
      tests `shouldNotSatisfy` isInfixOf "TestRunner"
      let sampled = call ["method" .= ("planGeneration" :: String), "target" .= ("rust" :: String),
            "sources" .= [rustSource], "generation" .= object ["exhaustiveLimit" .= (16 :: Int)]]
      diagnostics sampled `shouldBe` []
      content (fileWhere (== "tests/rust_example_lawspec.rs") sampled) `shouldSatisfy` isInfixOf "TestRunner"
      let right = field "right" (field "assertion" (head (list (field "laws" result))))
      text (field "kind" (field "node" right)) `shouldBe` "binary"
      text (field "name" (field "type" right)) `shouldBe` "Integer"
      text (field "file" (field "start" (field "span" (field "origin" right)))) `shouldBe` "rust.lawspec"
      field "original" (head (list (field "laws" result))) `shouldBe` Null
      field "typedExpressions" (head (list (field "laws" result))) `shouldBe` Null
    it "relocates the runtime, module declarations and test imports for custom layouts" $ do
      let result = call ["method" .= ("planGeneration" :: String), "target" .= ("rust" :: String),
            "sources" .= [rustSource], "sourceDir" .= ("library/core" :: String), "testDir" .= ("checks/unit" :: String)]
          paths = map (text . field "path") (files result)
      diagnostics result `shouldBe` []
      paths `shouldSatisfy` elem "library/core/lawspec_runtime.rs"
      paths `shouldSatisfy` elem "library/core/lawspec_modules.rs"
      paths `shouldSatisfy` elem "checks/unit/support/lawspec_strategies.rs"
      let tests = content (fileWhere (== "checks/unit/rust_example_lawspec.rs") result)
      tests `shouldSatisfy` isInfixOf "../../library/core/lawspec_runtime.rs"
      tests `shouldSatisfy` isInfixOf "../../library/core/rust_example.rs"

  describe "native bindings" $ do
    payments <- runIO (readFile "examples/specs/payments.lawspec")
    bindings <- runIO (fromMaybe Null . decode <$> BL.readFile "test/fixtures/native-payments/bindings.json")
    let paymentSources = [source "payments.lawspec" payments]
        request method extra = call (["method" .= (method :: String), "sources" .= paymentSources] ++ extra)
    it "negotiate schema 4, and schema 3 cannot silently ignore them" $ do
      let valid = request "check" ["nativeBindings" .= bindings, "schemaVersion" .= (4 :: Int)]
      field "schemaVersion" valid `shouldBe` Number 4
      diagnostics valid `shouldBe` []
      let incompatible = request "check" ["nativeBindings" .= bindings, "schemaVersion" .= (3 :: Int)]
      fst (firstDiagnostic incompatible) `shouldBe` "request"
      snd (firstDiagnostic incompatible) `shouldSatisfy` isInfixOf "requires API schemaVersion 4"
    it "reject unknown configuration fields and invalid symbols" $
      forM_ [ object ["tyeps" .= ([] :: [Value])]
            , object ["functions" .= [object ["declaration" .= ("example.payments::addFee" :: String), "native" .= ("app.call()" :: String)]]] ] $ \b ->
        fst (firstDiagnostic (request "check" ["nativeBindings" .= b, "schemaVersion" .= (4 :: Int)])) `shouldBe` "request"
    it "generate Rust bridges that link shared application-library types" $ do
      let result = request "planGeneration" ["nativeBindings" .= bindings, "schemaVersion" .= (4 :: Int), "target" .= ("rust" :: String)]
      diagnostics result `shouldBe` []
      let adapter = fileWhere ("example/payments.rs" `isSuffixOf`) result
      text (field "ownership" adapter) `shouldBe` "generated"
      content adapter `shouldNotSatisfy` isInfixOf "todo!"
      let tests = content (fileWhere ("_lawspec.rs" `isSuffixOf`) result)
      tests `shouldSatisfy` isInfixOf "use lawspec_example::lawspec_runtime;"
      tests `shouldSatisfy` isInfixOf "use lawspec_example::example_payments as adapter;"

  describe "generator scaffolds" $ do
    let stub = source "stub.lawspec" "unit stub"
        binding = [("type", String "Int8"), ("factory", toJSON ["factories", "values" :: String])]
        generator extra = object (map (\(k, v) -> K.fromString k .= v) (binding ++ extra))
        plan target generators = call ["method" .= ("planGeneration" :: String), "target" .= (target :: String),
          "schemaVersion" .= (4 :: Int), "sources" .= [stub], "nativeBindings" .= object ["generators" .= generators]]
    it "are opt-in and reject ambiguous requests" $ do
      let ordinary = plan "python" [generator []]
      diagnostics ordinary `shouldBe` []
      map (text . field "path") (files ordinary) `shouldNotSatisfy` elem "tests/factories.py"
      forM_ [ ["lawspec_native_generators","values"], ["lawspec_runtime","values"], ["hypothesis","values"]
            , ["typing","values"], ["decimal","values"], ["sys","values"], ["factories","_strategies" :: String] ] $ \factory -> do
        let result = plan "python" [generator [("factory", toJSON factory), ("stub", Bool True)]]
        fst (firstDiagnostic result) `shouldBe` "native-binding"
        snd (firstDiagnostic result) `shouldSatisfy` isInfixOf "conflict"
      forM_ [ [generator [("stub", Bool True)], generator [("type", String "Int16")]]
            , [generator [("stub", Bool True)], generator [("type", String "Int16"),
                ("factory", toJSON ["factories", "nested", "values" :: String]), ("stub", Bool True)]] ] $ \generators ->
        fst (firstDiagnostic (plan "python" generators)) `shouldBe` "native-binding"
      fst (firstDiagnostic (plan "python" [generator [("stub", String "yes")]])) `shouldBe` "request"
      let shadowed = call ["method" .= ("planGeneration" :: String), "target" .= ("python" :: String), "schemaVersion" .= (4 :: Int),
            "sources" .= [source "stub.lawspec" "unit stub\nf :: Int8 -> Int8"],
            "nativeBindings" .= object [ "functions" .= [object ["declaration" .= ("stub::f" :: String), "native" .= ["factories", "echo" :: String]]]
                                       , "generators" .= [generator [("stub", Bool True)]] ]]
      fst (firstDiagnostic shadowed) `shouldBe` "native-binding"
      snd (firstDiagnostic shadowed) `shouldSatisfy` isInfixOf "conflicts with another module"
    it "reject ambiguous Rust modules and normalized factory paths" $
      forM_ [ [["application","factory"]], [["proptest","factory"]], [["ls_gen","factory"]]
            , [["Vec","factory"]], [["ValueStrategy","factory"]], [["factories","std","factory"]]
            , [["lawspec_strategies","factory"]], [["only_name"]]
            , [["factories","values"],["crate","factories","values"]]
            , [["factories","nested"],["factories","nested","values"]]
            , [["factories","values"],["Factories","other" :: String]] ] $ \factories -> do
        let result = call ["method" .= ("planGeneration" :: String), "target" .= ("rust" :: String), "schemaVersion" .= (4 :: Int),
              "sources" .= [stub], "nativeBindings" .= object ["rustCrate" .= ("application" :: String),
                "generators" .= [object ["type" .= (if index > 0 then "Int16" else "Int8" :: String), "factory" .= factory, "stub" .= True]
                                | (index, factory) <- zip [0 :: Int ..] factories]]]
        diagnostics result `shouldNotBe` []
        snd (firstDiagnostic result) `shouldSatisfy` isInfixOf "scaffold"
    let scaffold target sourceText extra factory = call ["method" .= ("planGeneration" :: String), "target" .= (target :: String),
          "schemaVersion" .= (4 :: Int), "sources" .= [source "stub.lawspec" sourceText],
          "nativeBindings" .= object (("generators" .= [object ["type" .= ("Int8" :: String), "factory" .= (factory :: [String]), "stub" .= True]]) : extra)]
        rejected check result = do
          fst (firstDiagnostic result) `shouldBe` "native-binding"
          snd (firstDiagnostic result) `shouldSatisfy` check
        law = "law `identity` is definition is `for all` (x :: Int8) . x = x end end"
    it "reject inaccessible, colliding and inherited Java method names" $
      forM_ [ ["Factories","values"], ["lawspec","runtime","LawSpecRuntime","values"]
            , ["lawspec","testing","LawSpecNativeGenerators","values"], ["application","java","values"]
            , ["java","util","Factories","values"], ["org","jetbrains","jetCheck","Generator","values"]
            , ["application","Factories","wait"] ] $
        rejected (isInfixOf "scaffold") . scaffold "java" "unit stub" []
    it "reject conflicting Kotlin objects and reserved namespaces" $
      forM_ [ ["Factories","values"], ["application","Factories","toString"], ["kotlin","Factories","values"]
            , ["application","kotlin","values"], ["lawspec","testing","LawSpecNativeGenerators","values"]
            , ["io","kotest","property","Arb","values"] ] $
        rejected (isInfixOf "scaffold") . scaffold "kotlin" "unit stub" []
    it "diagnose unused Go bindings, imported factories and package identifier conflicts" $ do
      forM_ [["panic"], ["rapid"], ["fmt"], ["TestValues"], ["lawSpecNativeFactories"]] $
        rejected (lineMatches ["scaffold", "conflicts"]) . scaffold "go" ("unit stub\n" ++ law) []
      snd (firstDiagnostic (scaffold "go" "unit stub" [] ["NativeBytes"])) `shouldSatisfy` isInfixOf "requires a quantified use"
      let imported = scaffold "go" ("unit stub\n" ++ law)
            ["goImports" .= [object ["alias" .= ("app" :: String), "path" .= ("example.com/application" :: String)]]] ["app", "Bytes"]
      snd (firstDiagnostic imported) `shouldSatisfy` isInfixOf "package-local factories"
    it "scope Go scaffold collisions to their consuming package" $ do
      let plan contents = call ["method" .= ("planGeneration" :: String), "target" .= ("go" :: String), "schemaVersion" .= (4 :: Int),
            "sources" .= [source ("scope" ++ show i ++ ".lawspec") c | (i, c) <- zip [0 :: Int ..] contents],
            "nativeBindings" .= object [ "functions" .= [object ["declaration" .= ("first::echo" :: String), "native" .= ["Shared" :: String]]]
                                       , "generators" .= [object ["type" .= ("Int8" :: String), "factory" .= ["Shared" :: String], "stub" .= True]] ]]
          separate = plan ["unit first\necho :: Int8 -> Int8", "unit second\n" ++ law]
          paths = map (text . field "path") (files separate)
      diagnostics separate `shouldBe` []
      paths `shouldSatisfy` elem "second/native_generators_test.go"
      paths `shouldNotSatisfy` elem "first/native_generators_test.go"
      snd (firstDiagnostic (plan ["unit first\necho :: Int8 -> Int8\n" ++ law])) `shouldSatisfy` lineMatches ["scaffold", "conflicts"]
    it "reject Haskell generated, application and runtime module collisions" $ do
      let bound = ["functions" .= [object ["declaration" .= ("stub::echo" :: String), "native" .= ["Application", "Domain", "echo" :: String]]]]
      forM_ [ ["Prelude","bytes"], ["Data","Int","bytes"], ["Hedgehog","Gen","bytes"], ["Numeric","bytes"]
            , ["Test","Hspec","bytes"], ["LawSpecNativeGenerators","bytes"], ["Application","Domain","bytes"] ] $
        rejected (\m -> "scaffold" `isInfixOf` m || "shadows" `isInfixOf` m) . scaffold "haskell" "unit stub\necho :: Int8 -> Int8" bound
      let application = scaffold "haskell" "unit stub" [] ["Data", "Application", "bytes"]
      diagnostics application `shouldBe` []
      map (text . field "path") (files application) `shouldSatisfy` elem "test/Data/Application.hs"
