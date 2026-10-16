module SourceSyntaxSpec (test_sourceSyntax) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.List (nub)
import Data.Foldable (toList)
import Data.Aeson (Value(..), object, (.=), eitherDecode, encode, toJSON)
import qualified Data.Aeson.KeyMap as KM
import LawSpec.Api (dispatch)
import LawSpec.Compile (compileWithSourceSyntax,compileWithSettings)
import LawSpec.Model
import LawSpec.SourceSyntax

inventory sources = compileWithSourceSyntax False (\_ name -> name) (\_ _ -> Nothing) 64 defaultGeneration sources
nodesOf (Right (_,_,sources)) = concatMap syntaxNodes sources
nodesOf (Left _) = []
names kind nodes = [name | node <- nodes,syntaxKind node == kind,Just name <- [syntaxName node]]
response :: String -> Maybe String -> Source -> Either String Value
response method from source = eitherDecode (dispatch (encode (object
  (["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),"method" .= method,
    "verification" .= object ["layers" .= ([]::[String])],"sources" .= [source]] ++
    ["from" .= value | Just value <- [from]])))) :: Either String Value
field name (Object value) = KM.lookup name value
field _ _ = Nothing
clean result = case result of Right value -> field "diagnostics" value == Just (toJSONEmpty); _ -> False
  where toJSONEmpty = toJSON ([]::[String])

test_sourceSyntax = describe "checked migration source syntax" $ do
  let templates = Source "templates.lawspec" $ unlines
        [ "unit templates"
        , "definition identity (value :: a) :: a is value end"
        , "law `same` (operation :: a -> a) requires Eq a is"
        , "  definition is `for all` (value :: a) . operation value = value end"
        , "end" ]
  it "retains unused generic definitions and reusable laws before specialization" $ do
    let result = inventory [templates]
        nodes = nodesOf result
    names "declaration.definition" nodes `shouldBe` ["identity"]
    names "declaration.law" nodes `shouldBe` ["same"]
    names "capability" nodes `shouldBe` ["Eq"]
    [syntaxUses node | node <- nodes,syntaxKind node == "declaration.definition"] `shouldBe` [Just []]
    length [() | node <- nodes,syntaxKind node == "quantifier.forall"] `shouldBe` 1
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration [templates]
  it "retains explicit and inferred effects of unused generic definitions" $
    forM_ ["uses Clock ",""] $ \declared -> do
      let source = Source "effects.lawspec" ("unit effects\nability Clock is tick :: Bool -> Bool end\n" ++
            "definition observed (value :: a) :: a " ++ declared ++ "is tick true; value end\n")
          result = inventory [source]
          rows = [syntaxUses node | node <- nodesOf result,syntaxKind node == "declaration.definition"]
      fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
      fmap (fmap length) rows `shouldBe` [Just 1]
  it "retains checked equality operator tokens in an uninstantiated generic Boolean expression" $ do
    let source = Source "equality.lawspec" "unit equality\ndefinition same (left :: a) (right :: a) :: Bool requires Eq a is left == right && left == right end"
        result = inventory [source]
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    names "operator.value-equality" (nodesOf result) `shouldBe` ["==","=="]
  it "retains complete constructor applications on both sides of a comparison without changing expression origins" $ do
    let source = Source "applications.lawspec" ("unit applications\n" ++
          "type Runs is Runs first :: Bool second :: Bool again :: Bool end\n" ++
          "definition same (value :: Bool) :: Bool is Runs value false value == Runs value false value end")
        result = inventory [source]
        selected = [node | node <- nodesOf result,syntaxKind node == "application.constructor"]
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    map syntaxName selected `shouldBe` [Just "Runs",Just "Runs"]
    forM_ selected $ \node -> do
      let Span (Location _ startLine startColumn) (Location _ endLine endColumn) = syntaxSpan node
      startLine `shouldBe` endLine
      endColumn - startColumn `shouldSatisfy` (> length ("Runs " :: String))
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration [source]
  it "keeps type and natural-index parameters with their actual declaration kinds" $ do
    let source = Source "parameters.lawspec" $ unlines
          [ "unit parameters"
          , "type Box (a :: Type) is | Box value :: a end"
          , "type Token (n :: Natural) is | Zero where n = 0 end" ]
        result = inventory [source]
        nodes = nodesOf result
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    names "type-parameter" nodes `shouldBe` ["a","n"]
    names "type-parameter-kind" nodes `shouldBe` ["Type","Natural"]
    names "type-equation" nodes `shouldBe` ["n"]
  it "exports only supplied source files and deduplicates nested location wrappers" $ do
    let result = inventory [templates]
    fmap (\(_,_,sources) -> map syntaxPath sources) result `shouldBe` Right ["templates.lawspec"]
    let nodes = nodesOf result
    length nodes `shouldBe` length (nub nodes)
  it "retains the resolver's declaration identities through aliases and facade re-exports" $ do
    let sources =
          [ Source "base.lawspec" "unit base\ntype Pair (a :: Type) is Pair first :: a second :: a end"
          , Source "facade.lawspec" "unit facade\nimport base as original (Pair)\nexport Pair"
          , Source "use.lawspec" ("unit use\nimport facade as exposed (Pair)\n" ++
              "definition pair (first :: a) (second :: a) :: exposed.Pair a is exposed.Pair first second end") ]
        result = inventory sources
        bindings owner = case result of Right (_,_,syntax) -> concatMap syntaxBindings (filter ((== owner) . syntaxUnit) syntax); _ -> []
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    bindings "base" `shouldContain` [SyntaxBinding "type" "Pair" "base::type::Pair",SyntaxBinding "constructor" "Pair" "base::type::Pair::Pair"]
    bindings "facade" `shouldContain` [SyntaxBinding "constructor" "original.Pair" "base::type::Pair::Pair"]
    forM_ [SyntaxBinding "type" "exposed.Pair" "base::type::Pair",SyntaxBinding "constructor" "exposed.Pair" "base::type::Pair::Pair"] $ \binding ->
      bindings "use" `shouldContain` [binding]
    bindings "use" `shouldContain` [SyntaxBinding "constructor" "Pair" "base::type::Pair::Pair"]
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration sources
  it "distinguishes a local type from a same-spelled qualified imported type" $ do
    let sources =
          [ Source "base.lawspec" "unit base\ntype Choice is First | Second end"
          , Source "local.lawspec" "unit local\nimport base as original\ntype Choice is Local end\nf :: Choice -> original.Choice" ]
        result = inventory sources
        bindings = case result of Right (_,_,syntax) -> concatMap syntaxBindings (filter ((== "local") . syntaxUnit) syntax); _ -> []
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    bindings `shouldContain` [SyntaxBinding "type" "Choice" "local::type::Choice",SyntaxBinding "type" "original.Choice" "base::type::Choice"]
    bindings `shouldContain` [SyntaxBinding "constructor" "Local" "local::type::Choice::Local",SyntaxBinding "constructor" "original.First" "base::type::Choice::First"]
  it "distinguishes a shadowing refinement and a local collection type from built-in spellings" $ do
    let source = Source "shadow.lawspec" ("unit shadow\nrefinement BigUInt is UInt8 end\n" ++
          "type Set is Custom end\ndefinition identity (value :: BigUInt) :: BigUInt is value end\nf :: Set -> Set")
        result = inventory [source]
        bindings = case result of Right (_,_,syntax) -> concatMap syntaxBindings syntax; _ -> []
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    forM_ [SyntaxBinding "refinement" "BigUInt" "shadow::BigUInt",SyntaxBinding "type" "Set" "shadow::type::Set"] $ \binding ->
      bindings `shouldContain` [binding]
    bindings `shouldNotContain` [SyntaxBinding "type" "Set" "lawspec.collections::type::Set"]
  it "publishes deterministic namespace bindings separately from source-node spans" $ do
    case response "migrationBaseline" (Just "0.24") templates of
      Left message -> expectationFailure message
      Right value -> case field "sourceSyntax" value of
        Just (Array syntax) -> case toList syntax of
          [source] -> field "bindings" source `shouldBe` Just (toJSON
            [SyntaxBinding "value" "identity" "templatesIdentity",SyntaxBinding "law" "same" "same (templates)"])
          _ -> expectationFailure "expected one supplied source syntax inventory"
        _ -> expectationFailure "expected a checked source syntax inventory"
  it "does not invent blocks from contextual function names or documentary words" $ do
    let source = Source "words.lawspec" $ unlines
          [ "unit words"
          , "-- handler imaginary for Ability is end; workflow fake is end"
          , "model :: Bool -> Bool"
          , "definition handler (value :: Bool) :: Bool is value end"
          , "definition workflow (value :: Bool) :: Bool is handler value end"
          , "law `description end` is definition is true = true end"
          , "description is \"handler imaginary for Ability is end\" end end" ]
        nodes = nodesOf (inventory [source])
    names "declaration.definition" nodes `shouldBe` ["handler","workflow"]
    names "declaration.signature" nodes `shouldBe` ["model"]
    names "declaration.handler" nodes `shouldBe` []
    names "declaration.workflow" nodes `shouldBe` []
    names "section" nodes `shouldBe` ["definition","description"]
  it "discards speculative refined-type records and keeps the actual parenthesized type" $ do
    let source = Source "alternatives.lawspec" "unit alternatives\ndefinition identity (value :: (Bool)) :: Bool is value end"
        nodes = nodesOf (inventory [source])
    names "type-name" nodes `shouldBe` ["Bool","Bool"]
    names "parameter" nodes `shouldBe` ["value"]
  it "retains exact Unicode and tab parser positions" $ do
    let source = Source "unicode.lawspec" "unit unicode\n-- 😀 description\ndefinition identity (value :: Bool) :: Bool is\n\tvalue\nend\n"
        selected = [syntaxSpan node | node <- nodesOf (inventory [source]),syntaxKind node == "expression.name",syntaxName node == Just "value"]
    map spanStart selected `shouldBe` [Location "unicode.lawspec" 4 9]
  it "records constructors, dependent fields, patterns, rows and each actual closer" $ do
    let source = Source "data.lawspec" $ unlines
          [ "unit data"
          , "type PairBool is PairBool first :: Bool second :: Bool end"
          , "definition first (value :: PairBool) :: Bool is match value with | PairBool a b -> a end end"
          , "law `first field` is definition is `for all` (value :: PairBool) . first value = first value end"
          , "table (value, expected) is row PairBool true false, true expect first value = expected end end" ]
        nodes = nodesOf (inventory [source])
    names "constructor-field" nodes `shouldBe` ["first","second"]
    names "pattern-constructor" nodes `shouldBe` ["PairBool"]
    names "pattern-binding" nodes `shouldBe` ["a","b"]
    length [() | node <- nodes,syntaxKind node == "table-row"] `shouldBe` 1
    names "closer" nodes `shouldBe` ["type","case","definition","definition","table","law"]
  it "cannot return syntax for undefined or nonterminating unused definitions" $
    forM_ ["definition invalid (unused :: a) :: Integer is 1 / 0 end",
           "definition loop (value :: a) :: Bool is loop value end"] $ \body ->
      inventory [Source "invalid.lawspec" ("unit invalid\n" ++ body)] `shouldSatisfy` isLeft
  it "requires an explicit schema-5 legacy migration entry point" $ do
    response "migrationBaseline" Nothing templates `shouldSatisfy` (not . clean)
    response "migrationBaseline" (Just ("0.23"::String)) templates `shouldSatisfy` (not . clean)
    let result = response "migrationBaseline" (Just ("0.24"::String)) templates
    result `shouldSatisfy` clean
    fmap (field "sourceLanguageProfile") result `shouldBe` Right (Just (String "0.24"))
    fmap (field "sourceSyntax") result `shouldSatisfy` either (const False) (/= Nothing)
  it "never shares legacy migration cache entries with canonical parsing" $ do
    let migration = response "migrationBaseline" (Just ("0.24"::String)) templates
        canonical = response "check" (Just ("0.24"::String)) templates
    migration `shouldSatisfy` clean
    canonical `shouldSatisfy` (not . clean)
    response "migrationBaseline" (Just ("0.24"::String)) templates `shouldBe` migration
  it "serializes syntax spans with the public start/end wire fields" $ do
    let result = response "migrationBaseline" (Just "0.24") templates
        nodes = case result of
          Right value -> case field "sourceSyntax" value of
            Just (Array sources) -> [node | source <- toList sources,Just (Array items) <- [field "nodes" source],node <- toList items]
            _ -> []
          _ -> []
    nodes `shouldSatisfy` (not . null)
    forM_ nodes $ \node -> case field "span" node of
      Nothing -> expectationFailure "source syntax node has no span"
      Just span -> do
        field "start" span `shouldSatisfy` (/= Nothing)
        field "end" span `shouldSatisfy` (/= Nothing)
        field "spanStart" span `shouldBe` Nothing
  it "retains ordinary optional-law selection and mandatory definition validation" $ do
    let source = Source "selection.lawspec" "unit selection\nlaw `false` is definition is false end end"
        result = response "migrationBaseline" (Just ("0.24"::String)) source
    result `shouldSatisfy` clean
    fmap (field "verification") result `shouldSatisfy` either (const False) (\value ->
      (value >>= field "intrinsicDefinitionChecks") == Just (Bool True))
