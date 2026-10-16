{-# LANGUAGE OverloadedStrings #-}
module MigrationTemplateSpec (test_migrationTemplates) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import Test.Hspec
import LawSpec.Api (dispatch)
import LawSpec.Model (Source(..))

field key (Object value) = KM.lookup key value
field _ _ = Nothing
capture sources = either fail pure (eitherDecode (dispatch (encode (object
  ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
   "method" .= ("migrationBaseline"::String),"from" .= ("0.24"::String),
   "verification" .= object ["layers" .= ([]::[String])],"sources" .= sources]))) :: Either String Value)
source body = [Source "templates.lawspec" ("unit templates\n" ++ body)]
core result = field "migrationSemantics" result
templates result = core result >>= field "sourceTemplates"
digest key result = templates result >>= field key
accepted sources = do
  result <- capture sources
  field "diagnostics" result `shouldBe` Just (Array mempty)
  (templates result >>= field "status") `shouldBe` Just (String "available")
  pure result
rows key result = case templates result >>= field key of
  Just (Array values) -> V.toList values
  _ -> []

test_migrationTemplates = describe "checked source template migration capture" $ do
  it "matches the same unused generic definition across the explicit language profiles" $ do
    before <- accepted (source "definition same (value :: a) :: a is value end")
    after <- either fail pure (eitherDecode (dispatch (encode (object
      ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),"migrationSnapshot" .= True,
       "verification" .= object ["layers" .= ([]::[String])],
       "sources" .= source "function same (value :: a) -> a is value end function"]))) :: Either String Value)
    field "diagnostics" after `shouldBe` Just (Array mempty)
    mapM_ (\key -> digest key before `shouldBe` digest key after) ["declarationsDigest","definitionTemplatesDigest"]
  it "compares renamed reusable-law bodies separately from their actual domain policy" $ do
    before <- accepted (source "law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end")
    after <- either fail pure (eitherDecode (dispatch (encode (object
      ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),"migrationSnapshot" .= True,
       "verification" .= object ["layers" .= ([]::[String])],
       "sources" .= source "law \"|same| (operation :: a -> a) requires Eq a is definition: for all (value :: a) => operation value must be value end end end"]))) :: Either String Value)
    field "diagnostics" after `shouldBe` Just (Array mempty)
    digest "declarationsDigest" before `shouldBe` digest "declarationsDigest" after
    digest "lawBodiesDigest" before `shouldBe` digest "lawBodiesDigest" after
    digest "lawTemplatesDigest" before `shouldNotBe` digest "lawTemplatesDigest" after
  it "retains unused generic bodies that concrete specialization discards" $ do
    before <- accepted (source "definition pick (left :: a) (right :: a) :: a requires Eq a is left end")
    after <- accepted (source "definition pick (left :: a) (right :: a) :: a requires Eq a is right end")
    (core before >>= field "programDigest") `shouldBe` (core after >>= field "programDigest")
    digest "definitionTemplatesDigest" before `shouldNotBe` digest "definitionTemplatesDigest" after
    rows "definitions" before `shouldSatisfy` any (\row -> field "comparisonId" row==Just (String "templates::pick"))
  it "retains capability requirements even when an unused body needs no operation" $ do
    before <- accepted (source "definition same (value :: a) :: a requires Eq a is value end")
    after <- accepted (source "definition same (value :: a) :: a requires Keyed a is value end")
    (core before >>= field "programDigest") `shouldBe` (core after >>= field "programDigest")
    digest "definitionTemplatesDigest" before `shouldNotBe` digest "definitionTemplatesDigest" after
    digest "declarationsDigest" before `shouldNotBe` digest "declarationsDigest" after
  it "retains unused reusable laws and their expanded assertions" $ do
    before <- accepted (source "law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end")
    after <- accepted (source "law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . value = value end end")
    (core before >>= field "programDigest") `shouldBe` (core after >>= field "programDigest")
    digest "lawTemplatesDigest" before `shouldNotBe` digest "lawTemplatesDigest" after
    rows "laws" before `shouldSatisfy` any (\row -> field "comparisonId" row==Just (String "templates::law::same"))
  it "excludes comment and coordinate changes while preserving all checked template values" $ do
    before <- accepted (source "definition same (value :: a) :: a is value end")
    after <- accepted [Source "moved.lawspec" "unit templates\n-- moved 😀\n\ndefinition same (value :: a) :: a is\n  value\nend\n"]
    mapM_ (\key -> digest key before `shouldBe` digest key after)
      ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]
  it "preserves literal values rather than treating phrase-looking text as a name" $ do
    before <- accepted (source "definition text (value :: Bool) :: Text is \"\\\"|same|\" end")
    after <- accepted (source "definition text (value :: Bool) :: Text is \"same\" end")
    digest "definitionTemplatesDigest" before `shouldNotBe` digest "definitionTemplatesDigest" after
  it "retains bound-variable and parameter relationships conservatively" $ do
    before <- accepted (source "definition pick (left :: a) (right :: a) :: a is left end")
    after <- accepted (source "definition pick (left :: a) (right :: a) :: a is right end")
    digest "declarationsDigest" before `shouldNotBe` digest "declarationsDigest" after
  it "captures imported template bodies as well as their declaration owner" $ do
    let sources body = [Source "library.lawspec" ("unit library\ndefinition pick (left :: a) (right :: a) :: a is " ++ body ++ " end"),
          Source "consumer.lawspec" "unit consumer\nimport library as helpers"]
    before <- accepted (sources "left")
    after <- accepted (sources "right")
    (core before >>= field "programDigest") `shouldBe` (core after >>= field "programDigest")
    digest "definitionTemplatesDigest" before `shouldNotBe` digest "definitionTemplatesDigest" after
    rows "definitions" before `shouldSatisfy` any (\row -> field "comparisonId" row==Just (String "library::pick"))
  it "rejects unsafe unused generics before publishing any comparison metadata" $ do
    result <- capture (source "definition invalid (unused :: a) :: Integer is 1 / 0 end")
    field "diagnostics" result `shouldNotBe` Just (Array mempty)
    core result `shouldBe` Nothing
  it "retains nonempty declared effect rows even for an unused template" $ do
    before <- accepted (source "ability Clock is tick :: Bool -> Bool end\ndefinition same (value :: a) :: a uses Clock is value end")
    after <- accepted (source "ability Clock is tick :: Bool -> Bool end\ndefinition same (value :: a) :: a is value end")
    digest "declarationsDigest" before `shouldNotBe` digest "declarationsDigest" after
