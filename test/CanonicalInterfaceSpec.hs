-- | Ordinary hosts share one strict current interface.
module CanonicalInterfaceSpec (test_canonicalInterface) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Vector as V
import LawSpec.Api (dispatch)
import Test.Hspec

call fields = fromMaybe (error "invalid API response") $
  decode (dispatch (encode (object fields)))
field name (Object fields) = fromMaybe Null (KM.lookup name fields)
field _ _ = Null
items (Array values) = V.toList values
items _ = []
diagnostics = items . field "diagnostics"
source body = object ["path" .= ("boundary.lawspec" :: String), "content" .= ("unit boundary\n\n" ++ body ++ "\nend unit\n")]
profile = ["languageProfile" .= ("1.0-rc.2" :: String)]
layers names = object ["layers" .= (names :: [String])]

-- ref:REQ-compiler-api-contract
test_canonicalInterface :: Spec
test_canonicalInterface = describe "canonical interface cutoff" $ do
  it "rejects old schemas on every ordinary method, including harmless source" $
    forM_ ["check", "expand", "planGeneration", "format", "proofTasks"] $ \method ->
      forM_ [3,4 :: Int] $ \version -> do
        let result = call (profile ++ ["schemaVersion" .= version,
              "method" .= (method :: String), "sources" .= [source ""], "target" .= ("python" :: String)])
        field "schemaVersion" result `shouldBe` Number 5
        map (field "code") (diagnostics result) `shouldBe` [String "request"]
        show (diagnostics result) `shouldSatisfy` isInfixOf "schemaVersion 5"
  it "requires the exact explicit profile even when the schema is omitted" $ do
    let base = ["sources" .= [source ""]]
    forM_ [[], ["languageProfile" .= Null], ["languageProfile" .= ("0.24" :: String)]] $ \extra ->
      map (field "code") (diagnostics (call (base ++ extra))) `shouldBe` [String "request"]
    diagnostics (call (base ++ profile)) `shouldBe` []
    diagnostics (call (base ++ profile ++ ["schemaVersion" .= (5 :: Int)])) `shouldBe` []
  it "defaults to no selected law checks and does not claim verification" $ do
    let body = "law falseClaim is definition: false end definition end law\n"
    forM_ [[], ["verification" .= layers []]] $ \extra -> do
      let result = call (profile ++ ["sources" .= [source body]] ++ extra)
      diagnostics result `shouldBe` []
      field "verification" result `shouldBe` object
        ["layers" .= ([] :: [String]), "selection" .= ("no-selected-checks" :: String),
         "intrinsicDefinitionChecks" .= True]
      let evidence = filter ((== String "law") . field "stage") (items (field "evidence" result))
      evidence `shouldNotBe` []
      map (field "status") evidence `shouldBe` [String "not-verified"]
    diagnostics (call (profile ++ ["sources" .= [source body], "verification" .= layers ["exhaustive"]]))
      `shouldNotBe` []
  it "retains mandatory definition admission without selected law checks" $
    forM_ [ "function loops (x :: Integer) -> Integer is loops x end function\n"
          , "function unsafe (x :: Integer) -> Integer is prelude.quot x 0 end function\n" ] $ \body -> do
      let result = call (profile ++ ["sources" .= [source body], "verification" .= layers []])
      diagnostics result `shouldNotBe` []
      map (field "code") (diagnostics result) `shouldNotContain` [String "request", String "parse"]
  it "rejects legacy grammar without a compatibility entry point" $ do
    let legacy="definition twice (x :: Integer) :: Integer is x + x end"
        input=["sources" .= [source legacy]]
    forM_ ["check","expand","format","planGeneration"] $ \method -> do
      let result=call (profile ++ input ++ ["method" .= (method::String),"target" .= ("python"::String),"from" .= ("0.24"::String)])
      diagnostics result `shouldNotBe` []
    let removed=call (profile ++ ["sources" .= [source ""],"method" .= ("migrationBaseline"::String)])
    map (field "code") (diagnostics removed) `shouldBe` [String "request"]
  it "accepts native bindings through the same canonical schema" $ do
    let result = call (profile ++ ["sources" .= [source "echo of type Int8 -> Int8"],
          "nativeBindings" .= object ["functions" .= [object
            ["declaration" .= ("boundary::echo" :: String), "native" .= ["Application", "echo" :: String]]]]])
    field "schemaVersion" result `shouldBe` Number 5
    diagnostics result `shouldBe` []
