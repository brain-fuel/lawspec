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
canonicalCapture sources = either fail pure (eitherDecode (dispatch (encode (object
  ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
   "migrationSnapshot" .= True,"verification" .= object ["layers" .= ([]::[String])],
   "sources" .= sources]))) :: Either String Value)
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
  it "normalizes handler-association law keys while preserving the selected handler" $ do
    let declarations = "ability Signal is signal :: Bool -> Bool end\n" ++
          "handler remembering for Signal with state previous :: Bool start false is signal value is ~previous := !previous && value; previous end end\n" ++
          "handler other for Signal with state previous :: Bool start false is signal value is ~previous := !previous && value; previous end end\n"
        beforeBody = declarations ++ "law `twice` using remembering is definition is (signal true; signal true) = false end end"
        afterBody handler = declarations ++ "law \"|twice| using " ++ handler ++ " is definition: (signal true; signal true) must be false end end"
    before <- accepted (source beforeBody)
    after <- canonicalCapture (source (afterBody "remembering"))
    changed <- canonicalCapture (source (afterBody "other"))
    mapM_ (\result -> field "diagnostics" result `shouldBe` Just (Array mempty)) [after,changed]
    digest "declarationsDigest" before `shouldBe` digest "declarationsDigest" after
    digest "lawBodiesDigest" before `shouldBe` digest "lawBodiesDigest" after
    digest "declarationsDigest" before `shouldNotBe` digest "declarationsDigest" changed
  it "normalizes a harness law target without changing its settings or literal labels" $ do
    let beforeBody = "law `kept` is definition is true end end\n" ++
          "harness configured for templates is\nfor law `kept`\nrepeat 2\nlabel \"kept\"\nend"
        afterBody repetitions = "law \"|kept| is definition: true end end\n" ++
          "harness configured for templates is\nfor law \"|kept|\nrepeat " ++ show repetitions ++ "\nlabel \"kept\"\nend"
    before <- accepted (source beforeBody)
    after <- canonicalCapture (source (afterBody (2::Int)))
    changed <- canonicalCapture (source (afterBody (3::Int)))
    mapM_ (\result -> field "diagnostics" result `shouldBe` Just (Array mempty)) [after,changed]
    digest "declarationsDigest" before `shouldBe` digest "declarationsDigest" after
    digest "declarationsDigest" before `shouldNotBe` digest "declarationsDigest" changed
  it "keeps compiler-provided template policies stable for a monomorphic project with no laws" $ do
    before <- accepted (source "definition same (value :: Bool) :: Bool is value end")
    after <- canonicalCapture (source "function same (value :: Bool) -> Bool is value end function")
    field "diagnostics" after `shouldBe` Just (Array mempty)
    mapM_ (\key -> digest key before `shouldBe` digest key after)
      ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]
    let policies result = maybe [] (\value -> case field "domainPolicies" value of
          Just (Array entries) -> V.toList entries
          _ -> []) (templates result)
    policies before `shouldSatisfy` (not . null)
    policies before `shouldBe` policies after
    map (field "policy") (policies after) `shouldSatisfy` all (== Just (String "nonempty"))
  it "changes the authored law policy while retaining every versioned dependency policy" $ do
    before <- accepted (source "law `kept` is definition is `for all` (value :: Bool) . value = value end end")
    after <- canonicalCapture (source "law \"|kept| is definition: for all (value :: Bool) => value = value end end end")
    field "diagnostics" after `shouldBe` Just (Array mempty)
    let policies result = case templates result >>= field "domainPolicies" of
          Just (Array entries) -> V.toList entries
          _ -> []
        authored row = field "comparisonId" row == Just (String "templates::law::kept")
    map (field "policy") (filter authored (policies before)) `shouldBe` [Just (String "nonempty")]
    map (field "policy") (filter authored (policies after)) `shouldBe` [Just (String "universal")]
    filter (not . authored) (policies before) `shouldBe` filter (not . authored) (policies after)
    digest "lawBodiesDigest" before `shouldBe` digest "lawBodiesDigest" after
    digest "lawTemplatesDigest" before `shouldNotBe` digest "lawTemplatesDigest" after
  it "keeps canonical prelude applications universal even when their concrete input type is empty" $ do
    mapM_ (\(declaration,ty) -> do
      result <- canonicalCapture (source (declaration ++ "operation :: " ++ ty ++ " -> " ++ ty ++ "\n" ++
        "law kept is definition: apply law prelude.\"|idempotent| operation end end"))
      field "diagnostics" result `shouldBe` Just (Array mempty)
      let properties = case field "laws" result of
            Just (Array entries) -> filter (\row -> field "owner" row == Just (String "templates")) (V.toList entries)
            _ -> []
      map (field "inputDomain") properties `shouldBe` [Just (String "universal")])
      [("","Bool"),("type Empty is one of end type\n","Empty")]
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

  describe "source-template input domains" $ do
    let domains result = case templates result >>= field "inputDomains" >>= field "domains" of
          Just (Array values) -> V.toList values
          _ -> []
        selected result = case filter (\row -> field "comparisonId" row==Just (String "templates::law::domain")) (domains result) of
          [row] -> pure row
          _ -> fail "expected exactly one source-template input domain"
        reusable inputs claim = source ("law `domain` (operation :: Bool -> Bool) is definition is `for all` " ++ inputs ++ " . " ++ claim ++ " end end")
        status result = selected result >>= \row -> pure (field "status" row)
    it "anchors every domain row to the full admitted source-template capture" $ do
      result <- accepted (reusable "(value :: Bool)" "operation value = value")
      let evidence = templates result >>= field "inputDomains"
      (evidence >>= field "lawBodiesEvaluated") `shouldBe` Just (Bool False)
      mapM_ (\key -> (evidence >>= field "sourceTemplates" >>= field key) `shouldBe` digest key result)
        ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]
      length (domains result) `shouldBe` length (rows "laws" result)
    it "establishes a uniform Bool witness without choosing a law function parameter" $ do
      result <- accepted (reusable "(value :: Bool)" "operation value = value")
      status result `shouldReturn` Just (String "inhabited")
      (core result >>= field "domainPolicies") `shouldBe` Just (Array mempty)
    it "reuses a concrete input tuple without executing a false law" $ do
      result <- accepted (source "law `domain` is definition is `for all` (value :: Bool) . false end end")
      status result `shouldReturn` Just (String "inhabited")
    it "does not execute an undefined reusable-law body" $ do
      result <- accepted (reusable "(value :: Bool)" "(1 / 0 :: Integer) = 0")
      status result `shouldReturn` Just (String "inhabited")
    it "records a complete population counterexample when a formal value admits no legal inputs" $ do
      result <- accepted (source "law `domain` (required :: Bool) is definition is `for all` (value :: Bool where required) . true end end")
      status result `shouldReturn` Just (String "parameter-counterexample")
      row <- selected result
      field "complete" row `shouldBe` Just (Bool True)
      field "formalParameterCount" row `shouldBe` Just (Number 1)
      field "witness" row `shouldBe` Nothing
      case field "parameters" row of
        Just (Array values) | [binding]<-V.toList values ->
          (field "value" binding >>= field "value") `shouldBe` Just (Bool False)
        _->expectationFailure "missing admissible formal-value counterexample"
    it "keeps a generic element domain unsupported rather than inventing a value" $ do
      result <- accepted (source "law `domain` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end")
      status result `shouldReturn` Just (String "unsupported")
    it "records complete emptiness independently of a false law body" $ do
      result <- accepted (reusable "(value :: Bool where false)" "false")
      status result `shouldReturn` Just (String "empty")
      row <- selected result
      field "complete" row `shouldBe` Just (Bool True)
    it "preserves dependent input order and restrictions" $ do
      result <- accepted (reusable "(first :: Bool where first) (second :: Bool where second == first)" "false")
      status result `shouldReturn` Just (String "inhabited")
      row <- selected result
      field "inputCount" row `shouldBe` Just (Number 2)
    it "retains checked predicate dependencies behind the same reusable domain" $ do
      let body predicate=source ("definition allowed (value :: Bool) :: Bool is " ++ predicate ++ " end\n" ++
            "law `domain` (operation :: Bool -> Bool) is definition is `for all` (value :: Bool where allowed value) . operation value = value end end")
      before <- accepted (body "value") >>= selected
      after <- accepted (body "value == false") >>= selected
      field "status" before `shouldBe` Just (String "inhabited")
      field "status" after `shouldBe` Just (String "inhabited")
      field "domainDigest" before `shouldNotBe` field "domainDigest" after

    it "does not confuse an input shadowing a law parameter with a dependency on that parameter" $ do
      result <- accepted (reusable "(operation :: Bool where operation)" "operation = operation")
      status result `shouldReturn` Just (String "inhabited")
    it "records a bounded miss without claiming complete emptiness" $ do
      result <- accepted (reusable "(value :: Integer where value * value == -1)" "false")
      status result `shouldReturn` Just (String "incomplete")
      row <- selected result
      field "complete" row `shouldBe` Just (Bool False)
      field "witness" row `shouldBe` Nothing
    it "supports the one empty input tuple uniformly without evaluating generic law parameters" $ do
      result <- accepted (source "law `domain` (operation :: a -> a) is definition is true end end")
      status result `shouldReturn` Just (String "inhabited")
      row <- selected result
      field "inputCount" row `shouldBe` Just (Number 0)
      field "witness" row `shouldBe` Just (Array mempty)

    it "retains unused polymorphic constructor fields in the domain-only program" $ do
      result <- accepted (source ("type Box (a :: Type) is Box value :: a end\n" ++
        "law `domain` (operation :: Bool -> Bool) is definition is `for all` (value :: Box Bool) . false end end"))
      status result `shouldReturn` Just (String "inhabited")
      row <- selected result
      field "witness" row `shouldSatisfy` (/= Nothing)
    it "checks intrinsic field restrictions of unused nominal constructors" $ do
      result <- accepted (source ("type Positive is Positive value :: (n :: UInt8 where n > 0) end\n" ++
        "law `domain` (operation :: Bool -> Bool) is definition is `for all` (value :: Positive) . false end end"))
      status result `shouldReturn` Just (String "inhabited")
      row <- selected result
      case field "witness" row of
        Just (Array bindings) | [binding] <- V.toList bindings ->
          case field "value" binding >>= field "fields" of
            Just (Array values) | [value] <- V.toList values ->
              field "value" value `shouldSatisfy` (\case Just (Number n) -> n > 0; Just (String n) -> n /= "0"; _ -> False)
            _ -> expectationFailure "missing intrinsic field witness"
        _ -> expectationFailure "missing input witness"
