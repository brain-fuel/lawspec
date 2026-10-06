-- | Native binding requests at the public request boundary.
module NativeRequestSpec (test_nativeBindingRequestsAreValidatedAtTheirBoundary) where

import Test.Hspec
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import qualified Data.Text as T
import Data.List (isInfixOf)
import qualified Data.ByteString.Lazy.Char8 as BC
import LawSpec.Api (dispatch)
import LawSpec.Common

run :: String -> Value -> Value
run source native = case eitherDecode (dispatch (encode (object
  ["schemaVersion" .= (4 :: Int), "method" .= ("check" :: String), "sources" .= [Source "binding" source], "nativeBindings" .= native]))) of
  Right value -> value
  Left problem -> error problem
codes :: Value -> [Value]
codes (Object result) = case KM.lookup "diagnostics" result of
  Just (Array values) -> [code | Object diagnostic <- toList values, Just code <- [KM.lookup "code" diagnostic]]
  _ -> []
codes _ = []

-- | Binding configuration is written by hand, so a misspelling must be an error
-- rather than silently ignored, and a binding must never replace a checked
-- definition. ref:DEC-native-bindings-typed-identity
-- ref:REQ-native-binding-requests
test_nativeBindingRequestsAreValidatedAtTheirBoundary :: Spec
test_nativeBindingRequestsAreValidatedAtTheirBoundary = describe "native binding requests" $ do
  it "rejects misspelled binding configuration instead of ignoring it" $
    codes (run "unit sample" (object ["tyeps" .= ([] :: [Value])])) `shouldBe` [String "request"]
  it "rejects executable native reference strings" $
    codes (run "unit sample\nf :: Int8 -> Int8" (object ["functions" .= [object
      ["declaration" .= ("sample::f" :: String), "native" .= ("app.f(value)" :: String)]]]))
      `shouldBe` [String "request"]
  it "resolves adapter identities but cannot replace checked total definitions" $ do
    let binding name = object ["functions" .= [object
          ["declaration" .= ("sample::" ++ name), "native" .= (["crate","domain","f"] :: [String])]]]
        source = "unit sample\nf :: Int8 -> Int8\ndefinition model (x :: Int8) :: Int8 is x end"
    codes (run source (binding "f")) `shouldBe` []
    codes (run source (binding "model")) `shouldBe` [String "native-binding"]
  it "validates the payment mapping through the public request boundary" $ do
    source <- readFile "examples/specs/payments.lawspec"
    bytes <- BL.readFile "test/fixtures/native-payments/bindings.json"
    case eitherDecode bytes of
      Left problem -> expectationFailure problem
      Right config -> codes (run source config) `shouldBe` []

  it "emits Kotlin scalar bridges even without structural declarations or laws" $ do
    let request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("kotlin" :: String)
          , "sources" .= [Source "binding" "unit sample\nf :: Int8 -> Int8"]
          , "nativeBindings" .= object ["functions" .= [object
              ["declaration" .= ("sample::f" :: String), "native" .= (["app","echo"] :: [String])]]]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []
  it "plans Kotlin generator-only requests" $ do
    let request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("kotlin" :: String)
          , "sources" .= [Source "binding" "unit sample"]
          , "nativeBindings" .= object ["generators" .= [object
              ["type" .= ("Unit" :: String), "factory" .= (["app","unit"] :: [String])]]]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "resolves Go calls without colliding with the application's exported adapter name" $ do
    let request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("go" :: String)
          , "sources" .= [Source "binding" "unit sample\nf :: Int8 -> Int8"]
          , "nativeBindings" .= object ["functions" .= [object
              ["declaration" .= ("sample::f" :: String), "native" .= (["F"] :: [String])]]]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []
  -- Each target's async bridge awaits the native task, then converts its
  -- result; the bindings are the asyncbindings acceptance suite's.
  describe "bridges async adapters to native tasks" $
    mapM_ (\(target,fragments) -> it target $ do
      source <- readFile "examples/specs/async_bindings.lawspec"
      bindings <- either error id . eitherDecode <$> BL.readFile ("acceptance/asyncbindings/" ++ target ++ "/bindings.json")
      let request = object
            [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
            , "target" .= (target :: String), "sources" .= [Source "warehouse" source]
            , "nativeBindings" .= (bindings :: Value) ]
      case eitherDecode (dispatch (encode request)) of
        Left problem -> expectationFailure problem
        Right value -> do
          codes value `shouldBe` []
          mapM_ (show value `shouldContain`) fragments)
      [ ("python", ["async def priceOf(", "await "]), ("javascript", ["export async function priceOf(", "await "])
      , ("typescript", ["Promise<number>", "await "]), ("java", [".thenApply(found ->", "CompletableFuture<java.lang.Long> count("])
      , ("kotlin", ["suspend fun priceOf("]), ("go", ["LawSpecTask[int32]", ".Await()"])
      , ("rust", [".await"]), ("haskell", ["P.IO I.Int32", "P.fmap"]) ]
  it "bridges Go handle methods and constructors, holding a bound handle by pointer" $ do
    source <- readFile "examples/specs/handles.lawspec"
    let call declaration key value = object ["declaration" .= ("example.handles::" ++ declaration :: String), key .= value]
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("go" :: String)
          , "sources" .= [Source "handles" source]
          , "nativeBindings" .= object
              [ "types" .= [object ["type" .= ("example.handles::type::Jobs" :: String), "native" .= (["Queue"] :: [String])]]
              , "functions" .= [call "newJobs" "constructor" (["NewQueue"] :: [String]),
                  call "submit" "method" ("Offer" :: String), call "take" "method" ("Poll" :: String),
                  call "pending" "method" ("Size" :: String)] ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> do
        codes value `shouldBe` []
        let text = show value
        mapM_ (\fragment -> text `shouldContain` fragment)
          [").Offer(", "NewQueue()", "lsNativeMaybe[int32](", "lsHandleCodec[*Queue]", "lawSpecBoundSubmit("]
  it "rejects undeclared Go import aliases instead of emitting unresolved references" $ do
    let request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("go" :: String)
          , "sources" .= [Source "binding" "unit sample\nf :: Int8 -> Int8"]
          , "nativeBindings" .= object ["functions" .= [object
              ["declaration" .= ("sample::f" :: String), "native" .= (["domain","F"] :: [String])]]]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` [String "native-binding"]

  it "validates Haskell references and rejects collisions with generated modules" $ do
    let request reference = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("haskell" :: String)
          , "sources" .= [Source "binding" "unit sample\nf :: Int8 -> Int8"]
          , "nativeBindings" .= object ["functions" .= [object
              ["declaration" .= ("sample::f" :: String), "native" .= (reference :: [String])]]]
          ]
        result reference = case eitherDecode (dispatch (encode (request reference))) of
          Left problem -> error problem
          Right value -> codes value
    mapM_ (\reference -> result reference `shouldBe` [String "native-binding"])
      [["app","echo"], ["App","Echo"], ["App","case"], ["Sample","echo"],
       ["LawSpecRuntime","echo"], ["LawSpecSchema","echo"], ["LawSpecNativeGenerators","echo"]]
    mapM_ (\reference -> result reference `shouldBe` [])
      [["P","echo"], ["Codec","echo"], ["Data","echo"], ["App","Nested","echo"]]

  it "validates Go module imports and restricts them to Go emission" $ do
    let request target imports reference = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= (target :: String)
          , "sources" .= [Source "binding" "unit sample\nf :: Int8 -> Int8"]
          , "nativeBindings" .= object ["goImports" .= (imports :: [Value]), "functions" .= [object
              ["declaration" .= ("sample::f" :: String), "native" .= (reference :: [String])]]]
          ]
        entry alias path = object ["alias" .= (alias :: String), "path" .= (path :: String)]
        result target imports reference = case eitherDecode (dispatch (encode (request target imports reference))) of
          Left problem -> error problem
          Right value -> codes value
        domain = entry "schema" "example.invalid/application/domain"
    result "go" [domain] ["schema","Echo"] `shouldBe` []
    result "go" [domain] ["schema","echo"] `shouldBe` [String "native-binding"]
    result "go" [domain,domain] ["schema","Echo"] `shouldBe` [String "native-binding"]
    result "go" [entry "schema" "../domain"] ["schema","Echo"] `shouldBe` [String "request"]
    result "go" [entry "schema" "example.invalid//domain"] ["schema","Echo"] `shouldBe` [String "request"]
    result "go" [entry "schema" "example.invalid/domain\"\n"] ["schema","Echo"] `shouldBe` [String "request"]
    result "python" [domain] ["schema","Echo"] `shouldBe` [String "native-binding"]

  it "accepts Haskell application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("haskell" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Domain", "Value"] :: [String]),
                "codec" .= object ["toNative" .= (["Hooks", "toNative"] :: [String]),
                  "fromNative" .= (["Hooks", "fromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["Domain", "copy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "bridges Haskell method and constructor bindings of a handle" $ do
    source <- readFile "examples/specs/handles.lawspec"
    let call name form = object ["declaration" .= ("example.handles::" ++ name :: String), form]
        request types = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("haskell" :: String), "sources" .= [Source "handles" source]
          , "nativeBindings" .= object
            [ "types" .= types
            , "functions" .= [call "newJobs" ("constructor" .= (["JobQueue", "new"] :: [String])),
                call "submit" ("method" .= ("push" :: String)), call "take" ("method" .= ("pop" :: String)),
                call "pending" ("method" .= ("size" :: String))]
            ]
          ]
        bound = [object ["type" .= ("example.handles::type::Jobs" :: String), "native" .= (["JobQueue", "Queue"] :: [String])]]
        response = dispatch (encode (request bound))
        text = BC.unpack response
    case eitherDecode response of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []
    -- Methods are called on the handle argument, and run as IO actions.
    text `shouldSatisfy` isInfixOf "LS.awaitTask ((NativeModule0.push (argument0) (argument1)))"
    text `shouldSatisfy` isInfixOf "LS.awaitTask ((NativeModule0.new))"
    -- A Unit result discards the native one.
    text `shouldSatisfy` isInfixOf "nativeResult `P.seq` Codec.encode ((Codec.unitCodec _lawspecSchema 64 :: Codec.Codec ())) (())"
    -- A method needs the handle bound, since the method lives in its module;
    -- the error names the handle and the entry to add.
    let unbound = dispatch (encode (request ([] :: [Value])))
    case eitherDecode unbound of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` [String "native-binding"]
    BC.unpack unbound `shouldSatisfy` isInfixOf "but Jobs has no type binding"
    BC.unpack unbound `shouldSatisfy` isInfixOf "example.handles::type::Jobs"

  it "accepts Python application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("python" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Domain", "Value"] :: [String]),
                "codec" .= object ["toNative" .= (["Hooks", "toNative"] :: [String]),
                  "fromNative" .= (["Hooks", "fromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["Domain", "copy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "accepts JavaScript application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("javascript" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Domain", "Value"] :: [String]),
                "codec" .= object ["toNative" .= (["Hooks", "toNative"] :: [String]),
                  "fromNative" .= (["Hooks", "fromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["Domain", "copy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "accepts TypeScript application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("typescript" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Domain", "Value"] :: [String]),
                "codec" .= object ["toNative" .= (["Hooks", "toNative"] :: [String]),
                  "fromNative" .= (["Hooks", "fromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["Domain", "copy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "accepts Java application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("java" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Domain", "Value"] :: [String]),
                "codec" .= object ["toNative" .= (["Hooks", "toNative"] :: [String]),
                  "fromNative" .= (["Hooks", "fromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["Domain", "copy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "accepts Kotlin application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("kotlin" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Domain", "Value"] :: [String]),
                "codec" .= object ["toNative" .= (["Hooks", "toNative"] :: [String]),
                  "fromNative" .= (["Hooks", "fromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["Domain", "copy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "accepts Go application codec hooks without constructor mappings" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("go" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["NativeValue"] :: [String]),
                "codec" .= object ["toNative" .= (["ToNative"] :: [String]),
                  "fromNative" .= (["FromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["NativeCopy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "renames Go canonical types when an application type uses their name" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        request = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("go" :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object
            [ "types" .= [object ["type" .= ("sample::type::Value" :: String),
                "native" .= (["Value"] :: [String]),
                "codec" .= object ["toNative" .= (["ToNative"] :: [String]),
                  "fromNative" .= (["FromNative"] :: [String])]]]
            , "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["NativeCopy"] :: [String])]]
            ]
          ]
    case eitherDecode (dispatch (encode request)) of
      Left problem -> expectationFailure problem
      Right value -> codes value `shouldBe` []

  it "requires paired structured codec hooks and rejects foreign target options" $ do
    let source = "unit sample\ntype Value is Value item :: Int8 end\nf :: Value -> Value"
        hook = object ["toNative" .= (["crate","codec","decode"] :: [String]),
          "fromNative" .= (["crate","codec","encode"] :: [String])]
        binding codec = object ["type" .= ("sample::type::Value" :: String),
          "native" .= (["crate","domain","Value"] :: [String]), "codec" .= codec]
        request target codec = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= (target :: String), "sources" .= [Source "binding" source]
          , "nativeBindings" .= object ["rustCrate" .= ("application" :: String), "types" .= [binding codec],
              "functions" .= [object ["declaration" .= ("sample::f" :: String),
                "native" .= (["crate","domain","copy"] :: [String])]]]
          ]
        result target codec = case eitherDecode (dispatch (encode (request target codec))) of
          Left problem -> error problem
          Right value -> codes value
    result "rust" hook `shouldBe` []
    result "go" hook `shouldBe` [String "native-binding"]
    result "rust" (object ["toNative" .= (["crate","decode"] :: [String])]) `shouldBe` [String "request"]
    result "rust" (object ["toNative" .= ("crate::decode" :: String),
      "fromNative" .= (["crate","encode"] :: [String])]) `shouldBe` [String "request"]

  it "bridges Rust handle methods and constructors to a bound native type" $ do
    source <- readFile "examples/specs/handles.lawspec"
    let method name native = object ["declaration" .= ("example.handles::" ++ name :: String), "method" .= (native :: String)]
        request types = object
          [ "schemaVersion" .= (4 :: Int), "method" .= ("planGeneration" :: String)
          , "target" .= ("rust" :: String), "sources" .= [Source "handles.lawspec" source]
          , "nativeBindings" .= object ["rustCrate" .= ("application" :: String),
              "types" .= types,
              "functions" .= [object ["declaration" .= ("example.handles::newJobs" :: String),
                  "constructor" .= (["crate","jobs","JobQueue","new"] :: [String])],
                method "submit" "offer", method "take" "poll", method "pending" "size"]]
          ]
        response types = either error id (eitherDecode (dispatch (encode (request types))))
        bridge value = concat [T.unpack s | Object o <- [value], Just (Array files) <- [KM.lookup "files" o],
          Object f <- toList files, KM.lookup "path" f == Just (String "src/example/handles.rs"),
          Just (String s) <- [KM.lookup "content" f]]
        bound = response [object ["type" .= ("example.handles::type::Jobs" :: String),
          "native" .= (["crate","jobs","JobQueue"] :: [String])]]
    codes bound `shouldBe` []
    let text = bridge bound
    text `shouldContain` "ls::Handle::new(_native_result)"
    text `shouldContain` "_native_self.poll()"
    -- A Unit result discards whatever the native method returns.
    text `shouldContain` "_native_self.offer(_native_arg1);"
    -- A method needs to know the native type it calls.
    codes (response ([] :: [Value])) `shouldBe` [String "rust"]
