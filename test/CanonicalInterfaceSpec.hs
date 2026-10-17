-- | Ordinary hosts have one canonical interface. The old grammar is available
-- only through the explicit, reporting-only migration boundary.
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
source body = object ["path" .= ("boundary.lawspec" :: String), "content" .= ("unit boundary\n" ++ body)]
profile = ["languageProfile" .= ("1.0-rc.1" :: String)]
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
        show (diagnostics result) `shouldSatisfy` isInfixOf "migrationBaseline"
  it "requires the exact explicit profile even when the schema is omitted" $ do
    let base = ["sources" .= [source ""]]
    forM_ [[], ["languageProfile" .= Null], ["languageProfile" .= ("0.24" :: String)]] $ \extra ->
      map (field "code") (diagnostics (call (base ++ extra))) `shouldBe` [String "request"]
    diagnostics (call (base ++ profile)) `shouldBe` []
    diagnostics (call (base ++ profile ++ ["schemaVersion" .= (5 :: Int)])) `shouldBe` []
  it "defaults to no selected law checks and does not claim verification" $ do
    let body = "law falseClaim is definition: false end end"
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
    forM_ [ "function loops (x :: Integer) -> Integer is loops x end function"
          , "function unsafe (x :: Integer) -> Integer is prelude.quot x 0 end function" ] $ \body -> do
      let result = call (profile ++ ["sources" .= [source body], "verification" .= layers []])
      diagnostics result `shouldNotBe` []
      map (field "code") (diagnostics result) `shouldNotContain` [String "request", String "parse"]
  it "admits legacy grammar only through an explicit migration request" $ do
    let input = ["sources" .= [source "definition twice (x :: Integer) :: Integer is x + x end"]]
        ordinary = call (profile ++ input)
        baseline = call (profile ++ input ++ ["method" .= ("migrationBaseline" :: String), "from" .= ("0.24" :: String)])
    diagnostics ordinary `shouldNotBe` []
    diagnostics baseline `shouldBe` []
    items (field "sourceSyntax" baseline) `shouldNotBe` []
    field "files" baseline `shouldBe` toJSON ([] :: [Value])
    field "baselineGeneration" baseline `shouldBe` Null
    map (field "code") (diagnostics (call (profile ++ input ++ ["method" .= ("migrationBaseline" :: String)])))
      `shouldBe` [String "request"]
  it "accepts native bindings through the same canonical schema" $ do
    let result = call (profile ++ ["sources" .= [source "echo of type Int8 -> Int8"],
          "nativeBindings" .= object ["functions" .= [object
            ["declaration" .= ("boundary::echo" :: String), "native" .= ["Application", "echo" :: String]]]]])
    field "schemaVersion" result `shouldBe` Number 5
    diagnostics result `shouldBe` []
