module SourceSyntaxSpec (test_sourceSyntax) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.List (nub)
import Data.Foldable (toList)
import Data.Aeson (Value(..), object, (.=), eitherDecode, encode, toJSON)
import qualified Data.Aeson.KeyMap as KM
import LawSpec.Api (dispatch)
import LawSpec.Compile (compileWithSourceSyntax,compileWithSettings,compileWithSourceOrigins)
import LawSpec.Packages (Package(..),Project(..),preparePackagesWithOrigins)
import LawSpec.SourceOrigins (insertSourceNames,originalLocation)
import LawSpec.Frontend (elaborate)
import LawSpec.Discharge (dischargeEvidence)
import qualified Data.Map.Strict as M
import LawSpec.Model
import LawSpec.SourceSyntax

inventory sources = compileWithSourceSyntax True (\_ name -> name) (\_ _ -> Nothing) 64 defaultGeneration sources
nodesOf (Right (_,_,sources)) = concatMap syntaxNodes sources
nodesOf (Left _) = []
names kind nodes = [name | node <- nodes,syntaxKind node == kind,Just name <- [syntaxName node]]
response :: String -> Source -> Either String Value
response method source = eitherDecode (dispatch (encode (object
  (["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.2"::String),"method" .= method,
    "verification" .= object ["layers" .= ([]::[String])],"sources" .= [source]])))) :: Either String Value
field name (Object value) = KM.lookup name value
field _ _ = Nothing
clean result = case result of Right value -> field "diagnostics" value == Just (toJSONEmpty); _ -> False
  where toJSONEmpty = toJSON ([]::[String])

packageVersions package versions =
  let multiple=length versions>1
      bridge=Package "shop.consumer" "1.0.0" (M.singleton "shop.tax" "^1.0.0")
        [Source "bridge.lawspec" "unit shop.consumer\nimport shop.tax.api\nend unit"]
      dependencies=M.fromList ([ ("shop.tax","^2.0.0") ]++[("shop.consumer","^1.0.0") | multiple])
  in (Project Nothing dependencies,map package versions++[bridge | multiple])

test_sourceSyntax = describe "checked source syntax" $ do
  it "retains original parser and intrinsic-definition error positions after namespace insertion" $ do
    let package version=Package "shop.tax" version M.empty
          [Source (version++".lawspec") "unit shop.tax.api\n\ntype Band is one of Low | High end type\nend unit\n"]
        run body versions=do
          let source=Source "invalid.lawspec" ("unit caller import shop.tax.api (Band) "++body++"\nend unit")
              (project,packages)=packageVersions package versions
          (prepared,origins,visible,referenceUnit,_)<-preparePackagesWithOrigins False
            project packages [source]
          compileWithSourceOrigins origins True False referenceUnit visible 64 defaultGeneration prepared
    forM_ ["function unsafe (value :: Integer) -> Integer is 1 / value end function\n",
           "function broken (value :: Integer) -> Integer is 1 + end function"] $ \body ->
      case (run body ["2.0.0"],run body ["1.0.0","2.0.0"]) of
        (Left plain,Left mapped) -> map (\diagnostic->(code diagnostic,at diagnostic)) mapped
          `shouldBe` map (\diagnostic->(code diagnostic,at diagnostic)) plain
        _ -> expectationFailure "expected both versions to reject the authored definition"
  it "retains authored spans through package qualifiers, implicit aliases, tabs and CRLF" $ do
    forM_ [True] $ \canonical -> forM_ [False,True] $ \explicit -> do
      let lawName=if canonical then "law same" else "`same`"
          pkgText=map (\character->if character=='\n' then ' ' else character) ("unit shop.tax.api\n\n"++
            (if canonical then "type Band is one of | Low | High end type\nfunction keep (value :: a) -> a is value end function\nlaw same (value :: Bool) is definition: value = value end definition end law\n"
             else "type Band is one of | Low | High end type\nfunction keep (value :: a) -> a is value end function\nlaw \"|same| (value :: Bool) is definition : value = value end definition end law\n") ++ "\nend unit\n")
          package version=Package "shop.tax" version M.empty [Source ("tax-"++version++".lawspec") pkgText]
          alias=if explicit then " as chosen" else ""
          selected=if explicit then "chosen" else "api"
          text="-- 😀 original coordinates\r\n\tunit caller\r\n\timport\tshop . tax . api"++alias++" (Band, keep, "++lawName++")\r\n"++
            (if canonical then "function echo (value :: Band) -> Band is "++selected++".keep value end function\r\nend unit"
             else "function echo (value :: Band) -> Band is "++selected++".keep value end function\r\nend unit")
          source=Source "caller.lawspec" text
          run versions=do
            let (project,packages)=packageVersions package versions
            (prepared,origins,visible,referenceUnit,_)<-preparePackagesWithOrigins canonical
              project packages [source]
            (units,properties,syntax)<-compileWithSourceOrigins origins True canonical referenceUnit visible 64 defaultGeneration prepared
            pure (units,properties,[node | input<-syntax,syntaxPath input=="caller.lawspec",node<-syntaxNodes input],
              [reference | input<-syntax,syntaxPath input=="caller.lawspec",reference<-syntaxReferences input],
              ([(syntaxKind node,syntaxSpan node) | input<-syntax,syntaxPath input=="tax-2.0.0.lawspec",node<-syntaxNodes input],
               [location law | unit<-units,law<-laws unit,file (location law)=="tax-2.0.0.lawspec"]))
      case (run ["2.0.0"],run ["1.0.0","2.0.0"]) of
        (Right (_,_,plain,plainReferences,plainPackage),Right (units,_,versioned,versionedReferences,versionedPackage)) -> do
          map (\node->(syntaxKind node,syntaxSpan node)) versioned `shouldBe` map (\node->(syntaxKind node,syntaxSpan node)) plain
          map referenceSpan versionedReferences `shouldBe` map referenceSpan plainReferences
          map referenceName versionedReferences `shouldContain` [selected++".keep"]
          versionedPackage `shouldBe` plainPackage
          [unitName unit | unit<-units] `shouldContain` ["shop.tax.v2x0x0.api"]
          [syntaxName node | node<-versioned,syntaxKind node=="import-item"] `shouldContain` [Just "Band"]
        result -> expectationFailure (show result)
  it "inserts qualifiers without changing body text, whitespace or a missing final newline" $ do
    let literal="unchanged\nimport shop.tax.api\nunit shop.tax.fake"
        text="-- unit shop.tax.fake\r\n\tunit\tshop . tax . api\r\n"++
          "function message (unused :: Bool) -> Text is \"unchanged\nimport shop.tax.api\nunit shop.tax.fake\" end function\nend unit"
        package version=Package "shop.tax" version M.empty [Source (version++".lawspec") text]
        (project,packages)=packageVersions package ["1.0.0","2.0.0"]
        caller=Source "caller.lawspec" ("unit caller\nimport shop.tax.api\n"++
          "law \"|literal unchanged| is definition: api.message true = "++show literal++" end definition end law\nend unit")
    case preparePackagesWithOrigins False project packages [caller] of
      Left ds -> expectationFailure (show ds)
      Right (prepared,origins,visible,referenceUnit,_) -> do
        let expected="-- unit shop.tax.fake\r\n\tunit\tshop . tax.v2x0x0 . api\r\n"++
              "function message (unused :: Bool) -> Text is \"unchanged\nimport shop.tax.api\nunit shop.tax.fake\" end function\nend unit"
        [content source | source<-prepared,path source=="2.0.0.lawspec"] `shouldBe` [expected]
        case compileWithSourceOrigins origins True False referenceUnit visible 64 defaultGeneration prepared of
          Left ds -> expectationFailure (show ds)
          Right (units,properties,_) -> case elaborate 64 units properties >>= dischargeEvidence of
            Left ds -> expectationFailure (show ds)
            Right _ -> pure ()
  it "qualifies separately supplied harness targets and retains their authored ranges" $ do
    let harness="harness checks for shop.tax.api is end harness\n"
        package version=Package "shop.tax" version M.empty
          [Source (version++".lawspec") "unit shop.tax.api\nend unit\n",
           Source (version++".harness.lawspec") harness]
        (project,packages)=packageVersions package ["1.0.0","2.0.0"]
    case preparePackagesWithOrigins False project packages [Source "caller.lawspec" "unit caller\nimport shop.tax.api\nend unit"] of
      Left ds -> expectationFailure (show ds)
      Right (prepared,origins,visible,referenceUnit,_) ->
        case compileWithSourceOrigins origins True False referenceUnit visible 64 defaultGeneration prepared of
          Left ds -> expectationFailure (show ds)
          Right (units,_,_) -> do
            let harnesses=[value | unit<-units,value<-maybe [] pure (unitHarness unit)]
            map harnessFor harnesses `shouldMatchList` ["shop.tax.v1x0x0.api","shop.tax.v2x0x0.api"]
            forM_ harnesses $ \value -> do
              let Span start end=harnessSpan value
              (line start,column start) `shouldBe` (1,1)
              (line end,column end) `shouldBe` (2,1)
  it "maps generated characters to their insertion site and retained Unicode/tab positions exactly" $ do
    let source=Source "coordinates.lawspec" "a😀\tb\r\nc"
    case insertSourceNames source [(1,".version"),(1," as original")] of
      Left reason -> expectationFailure reason
      Right (prepared,Just origins) -> do
        content prepared `shouldBe` "a.version as original😀\tb\r\nc"
        map (originalLocation origins) [1,9,21] `shouldBe` replicate 3 (Just (Location "coordinates.lawspec" 1 2))
        originalLocation origins 23 `shouldBe` Just (Location "coordinates.lawspec" 1 9)
        originalLocation origins (length (content prepared)) `shouldBe` Just (Location "coordinates.lawspec" 2 2)
      _ -> expectationFailure "expected an origin map"
  let templates = Source "templates.lawspec" $ unlines
        [ "unit templates"
         ++ "\n", ""
        , "function identity (value :: a) -> a is value end function\n"
        , "law \"|same| (operation :: a -> a) requires Eq a is"
        , "  definition : for all (value :: a) => operation value = value end for all end definition"
        , "end law"
        , "\nend unit" ]
  it "retains unused generic definitions and reusable laws before specialization" $ do
    let result = inventory [templates]
        nodes = nodesOf result
    names "declaration.definition" nodes `shouldBe` ["identity"]
    names "declaration.law" nodes `shouldBe` ["|same|"]
    names "capability" nodes `shouldBe` ["Eq"]
    [syntaxUses node | node <- nodes,syntaxKind node == "declaration.definition"] `shouldBe` [Just []]
    length [() | node <- nodes,syntaxKind node == "quantifier.forall"] `shouldBe` 1
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration [templates]
  it "retains explicit and inferred effects of unused generic definitions" $
    forM_ ["uses Clock ",""] $ \declared -> do
      let source = Source "effects.lawspec" ("unit effects\n\nability Clock is tick :: Bool -> Bool end ability\n" ++
            "procedure observed (value :: a) -> a " ++ declared ++ "is tick true; value end procedure\n" ++ "\nend unit\n")
          result = inventory [source]
          rows = [syntaxUses node | node <- nodesOf result,syntaxKind node == "declaration.definition"]
      fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
      fmap (fmap length) rows `shouldBe` [Just 1]
  it "retains checked equality operator tokens in an uninstantiated generic Boolean expression" $ do
    let source = Source "equality.lawspec" "unit equality\n\nfunction same (left :: a) (right :: a) -> Bool requires Eq a is left == right && left == right end function\nend unit\n"
        result = inventory [source]
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    names "operator.value-equality" (nodesOf result) `shouldBe` ["==","=="]
  it "retains complete constructor applications on both sides of a comparison without changing expression origins" $ do
    let source = Source "applications.lawspec" ("unit applications\n\n" ++
          "type Runs is a record{  first :: Bool second :: Bool again :: Bool} end type\n" ++
          "function same (value :: Bool) -> Bool is Runs value false value = Runs value false value end function\n" ++ "\nend unit\n")
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
           ++ "\n", ""
          , "type Box (a :: Type) is a record{   value :: a} end type\n"
          , "type Token (n :: Whole) is one of | Zero where n = 0 end type\n"
          , "\nend unit" ]
        result = inventory [source]
        nodes = nodesOf result
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    names "type-parameter" nodes `shouldBe` ["a","n"]
    names "type-parameter-kind" nodes `shouldBe` ["Type","Whole"]
    names "type-equation" nodes `shouldBe` ["n"]
  it "exports only supplied source files and deduplicates nested location wrappers" $ do
    let result = inventory [templates]
    fmap (\(_,_,sources) -> map syntaxPath sources) result `shouldBe` Right ["templates.lawspec"]
    let nodes = nodesOf result
    length nodes `shouldBe` length (nub nodes)
  it "retains the resolver's declaration identities through aliases and facade re-exports" $ do
    let sources =
          [ Source "base.lawspec" "unit base\n\ntype Pair (a :: Type) is a record{  first :: a second :: a} end type\nend unit\n"
          , Source "facade.lawspec" "unit facade\nimport base as original (Pair)\nexport Pair\nend unit"
          , Source "use.lawspec" ("unit use\nimport facade as exposed (Pair)\n" ++
              "function pair (first :: a) (second :: a) -> exposed.Pair a is exposed.Pair record{first=first, second=second} end function\nend unit") ]
        result = inventory sources
        bindings owner = case result of Right (_,_,syntax) -> concatMap syntaxBindings (filter ((== owner) . syntaxUnit) syntax); _ -> []
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    bindings "base" `shouldContain` [SyntaxBinding "type" "Pair" "base::type::Pair" Nothing,SyntaxBinding "constructor" "Pair" "base::type::Pair::Pair" Nothing]
    bindings "facade" `shouldContain` [SyntaxBinding "constructor" "original.Pair" "base::type::Pair::Pair" Nothing]
    forM_ [SyntaxBinding "type" "exposed.Pair" "base::type::Pair" Nothing,SyntaxBinding "constructor" "exposed.Pair" "base::type::Pair::Pair" Nothing] $ \binding ->
      bindings "use" `shouldContain` [binding]
    bindings "use" `shouldContain` [SyntaxBinding "constructor" "Pair" "base::type::Pair::Pair" Nothing]
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration sources
  it "distinguishes a local type from a same-spelled qualified imported type" $ do
    let sources =
          [ Source "base.lawspec" "unit base\n\ntype Choice is one of First | Second end type\nend unit\n"
          , Source "local.lawspec" "unit local\nimport base as original\ntype Choice is one of Local end type\nf :: Choice -> original.Choice\nend unit" ]
        result = inventory sources
        bindings = case result of Right (_,_,syntax) -> concatMap syntaxBindings (filter ((== "local") . syntaxUnit) syntax); _ -> []
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    bindings `shouldContain` [SyntaxBinding "type" "Choice" "local::type::Choice" Nothing,SyntaxBinding "type" "original.Choice" "base::type::Choice" Nothing]
    bindings `shouldContain` [SyntaxBinding "constructor" "Local" "local::type::Choice::Local" Nothing,SyntaxBinding "constructor" "original.First" "base::type::Choice::First" Nothing]
  it "distinguishes a shadowing refinement and a local collection type from built-in spellings" $ do
    let source = Source "shadow.lawspec" ("unit shadow\n\nrefinement BigUInt is UInt8 end refinement\n" ++
          "type Set is one of Custom end type\nfunction identity (value :: Whole) -> Whole is value end function\nf :: Set -> Set\n" ++ "\nend unit\n")
        result = inventory [source]
        bindings = case result of Right (_,_,syntax) -> concatMap syntaxBindings syntax; _ -> []
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    forM_ [SyntaxBinding "refinement" "BigUInt" "shadow::BigUInt" Nothing,SyntaxBinding "type" "Set" "shadow::type::Set" Nothing] $ \binding ->
      bindings `shouldContain` [binding]
    bindings `shouldNotContain` [SyntaxBinding "type" "Set" "lawspec.collections::type::Set" Nothing]
  it "records imported value occurrences while excluding parameter, let, case and quantifier shadows" $ do
    let source = Source "references.lawspec" $ unlines
          [ "unit references"
          , "import lawspec.collections as collections (setOf)"
          , "type Flag is a record{  value :: Bool} end type\n"
          , "function fromItems (items :: List Bool) -> Set Bool is setOf items end function\n"
          , "function fromQualified (items :: List Bool) -> Set Bool is collections.setOf items end function\n"
          , "function parameter (setOf :: Bool) -> Bool is setOf end function\n"
          , "function local (value :: Bool) -> Bool is let setOf = value in setOf end let end function\n"
          , "function branch (flag :: Flag) -> Bool is first matching case of flag : when Flag setOf then setOf end case end function\n"
          , "law \"|shadow| is definition : for all (setOf :: Bool) (next :: Bool where next = setOf) => next = setOf end for all end definition end law\n" , "end unit"]
        result = inventory [source]
        references = case result of Right (_,_,syntax) -> concatMap syntaxReferences syntax; _ -> []
        imported = [reference | reference <- references,referenceName reference `elem` ["setOf","collections.setOf"]]
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    map referenceName imported `shouldBe` ["setOf","collections.setOf"]
    map referenceTarget imported `shouldBe` replicate 2 "lawspecCollectionsEqSetOf"
    map referenceDeclaration imported `shouldBe` replicate 2 (Just "lawspec.collections::eqSetOf")
    map (line . spanStart . referenceSpan) imported `shouldBe` [5,7]
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration [source]
  it "records actual import/export item ranges without treating documentary words as items" $ do
    let sources =
          [ Source "model.lawspec" "unit model\n\ntype Flag is a record{  value :: Bool} end type\nend unit\n"
          , Source "facade.lawspec" "unit facade\n-- export fake\nimport model as original (Flag)\nexport original.Flag\nend unit" ]
        result = inventory sources
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    names "import-item" (nodesOf result) `shouldBe` ["Flag"]
    names "import-alias" (nodesOf result) `shouldBe` ["original"]
    names "export-item" (nodesOf result) `shouldBe` ["original.Flag"]
  it "retains source declaration identity through facades and distinguishes a same-spelled user function" $ do
    let sources =
          [ Source "model.lawspec" "unit model\n\nfunction setOf (value :: Bool) -> List Bool is [value] end function\nend unit\n"
          , Source "facade.lawspec" "unit facade\nimport model as original (setOf)\nexport setOf\nend unit"
          , Source "consumer.lawspec" ("unit consumer\nimport facade as custom\nimport lawspec.collections as collections (setOf)\n" ++
              "function customItems (value :: Bool) -> List Bool is custom.setOf value end function\n" ++
              "function orderedItems (values :: List Bool) -> Set Bool is (setOf) values end function\nend unit") ]
        result = inventory sources
        references = case result of Right (_,_,syntax) -> concatMap syntaxReferences (filter ((== "consumer") . syntaxUnit) syntax); _ -> []
        relevant = [reference | reference <- references,referenceName reference `elem` ["custom.setOf","setOf"]]
    fmap (\(_,_,_) -> ()) result `shouldBe` Right ()
    map referenceName relevant `shouldBe` ["custom.setOf","setOf"]
    map referenceDeclaration relevant `shouldBe` [Just "model::setOf",Just "lawspec.collections::eqSetOf"]
    let bindings = case result of Right (_,_,syntax) -> concatMap syntaxBindings (filter ((== "consumer") . syntaxUnit) syntax); _ -> []
    [bindingDeclaration binding | binding <- bindings,bindingName binding=="custom.setOf"] `shouldBe` [Just "model::setOf"]
    fmap (\(units,properties,_) -> (units,properties)) result `shouldBe` compileWithSettings 64 defaultGeneration sources
  it "does not invent blocks from contextual function names or documentary words" $ do
    let source = Source "words.lawspec" $ unlines
          [ "unit words"
           ++ "\n", ""
          , "-- handler imaginary for Ability is end; workflow fake is end"
          , "model :: Bool -> Bool\n"
          , "function handler (value :: Bool) -> Bool is value end function\n"
          , "function workflow (value :: Bool) -> Bool is handler value end function\n"
          , "law \"|description end| is definition : true = true end definition"
          , "description : \"handler imaginary for Ability is end\" end description end law"
          , "\nend unit" ]
        nodes = nodesOf (inventory [source])
    names "declaration.definition" nodes `shouldBe` ["handler","workflow"]
    names "declaration.signature" nodes `shouldBe` ["model"]
    names "declaration.handler" nodes `shouldBe` []
    names "declaration.workflow" nodes `shouldBe` []
    names "section" nodes `shouldBe` ["definition","description"]
  it "discards speculative refined-type records and keeps the actual parenthesized type" $ do
    let source = Source "alternatives.lawspec" "unit alternatives\n\nfunction identity (value :: (Bool)) -> Bool is value end function\nend unit\n"
        nodes = nodesOf (inventory [source])
    names "type-name" nodes `shouldBe` ["Bool","Bool"]
    names "parameter" nodes `shouldBe` ["value"]
  it "retains exact Unicode and tab parser positions" $ do
    let source = Source "unicode.lawspec" "unit unicode\n\n-- 😀 description\nfunction identity (value :: Bool) -> Bool is\n\tvalue\nend function\nend unit\n"
        selected = [syntaxSpan node | node <- nodesOf (inventory [source]),syntaxKind node == "expression.name",syntaxName node == Just "value"]
    map spanStart selected `shouldBe` [Location "unicode.lawspec" 5 9]
  it "uses code-point columns after wide and combining characters in the canonical grammar" $ do
    forM_ [True] $ \canonical -> do
      let prefix = if canonical
            then "function message (flag :: Bool) -> Text is "
            else "definition message (flag :: Bool) :: Text is "
          expression = "if flag then \"😀Ａe\x301\" else \"done\""
          closer = if canonical then " end if end function" else " end"
          source = Source "wide.lawspec" ("unit wide\r\n"++prefix++expression++closer++"\r\n" ++ "\nend unit\n")
          result = compileWithSourceSyntax canonical (\_ name->name) (\_ _->Nothing) 64 defaultGeneration [source]
          selected = [syntaxSpan node | node<-nodesOf result,syntaxKind node=="text"]
          afterFirst = length prefix + length ("if flag then \"😀Ａe\x301\" " :: String) + 1
          startSecond = afterFirst + length ("else " :: String)
      case result of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right _ -> do
          map spanStart selected `shouldBe`
            [Location "wide.lawspec" 2 (length prefix+length ("if flag then " :: String)+1),
             Location "wide.lawspec" 2 startSecond]
          map spanEnd selected `shouldBe`
            [Location "wide.lawspec" 2 afterFirst,
             Location "wide.lawspec" 2 (startSecond+length ("\"done\" " :: String))]
  it "reports parser errors in code-point columns after wide literals" $ do
    let prefix = "unit wide function broken (flag :: Bool) -> Text is if flag then \"😀Ａe\x301\" else "
        source = Source "wide-error.lawspec" (prefix++"end if end function")
    case compileWithSourceSyntax True (\_ name->name) (\_ _->Nothing) 64 defaultGeneration [source] of
      -- The identifier parser rejects the reserved word after consuming "end".
      Left diagnostics -> map at diagnostics `shouldBe` [Just (Location "wide-error.lawspec" 1 (length prefix+4))]
      Right _ -> expectationFailure "expected a malformed branch to be rejected"
  it "records constructors, dependent fields, patterns, rows and each actual closer" $ do
    let source = Source "data.lawspec" $ unlines
          [ "unit data"
           ++ "\n", ""
          , "type PairBool is a record{  first :: Bool second :: Bool} end type\n"
          , "function first (value :: PairBool) -> Bool is first matching case of value : when PairBool record{ first = a , second = b} then a end case end function\n"
          , "law \"|first field| is definition : for all (value :: PairBool) => first value = first value end for all end definition"
          , "expect first value = expected in table (value, expected) : row PairBool record{ first = true , second = false}, true end table end law"
          , "\nend unit" ]
        nodes = nodesOf (inventory [source])
    names "record-type-field" nodes `shouldBe` ["first","second"]
    names "pattern-constructor" nodes `shouldBe` ["PairBool"]
    names "pattern-binding" nodes `shouldBe` ["a","b"]
    length [() | node <- nodes,syntaxKind node == "table-row"] `shouldBe` 1
    names "closer" nodes `shouldBe` ["type","case","function","for all","definition","table","law","unit"]
  it "cannot return syntax for undefined or nonterminating unused definitions" $
    forM_ [ "function invalid (unused :: a) -> Integer is 1 / 0 end function\n"
          , "function loop (value :: a) -> Bool is loop value end function\n" ] $ \body ->
      inventory [Source "invalid.lawspec" ("unit invalid\n\n" ++ body ++ "\nend unit\n")] `shouldSatisfy` isLeft
  it "serializes syntax spans with the public start/end wire fields" $ do
    let nodes = map toJSON (nodesOf (inventory [templates]))
    nodes `shouldSatisfy` (not . null)
    forM_ nodes $ \node -> case field "span" node of
      Nothing -> expectationFailure "source syntax node has no span"
      Just span -> do
        field "start" span `shouldSatisfy` (/= Nothing)
        field "end" span `shouldSatisfy` (/= Nothing)
        field "spanStart" span `shouldBe` Nothing
  it "retains ordinary optional-law selection and mandatory definition validation" $ do
    let source = Source "selection.lawspec" "unit selection\n\nlaw \"|false| is definition : false end definition end law\nend unit\n"
        result = response "check" source
    result `shouldSatisfy` clean
    fmap (field "verification") result `shouldSatisfy` either (const False) (\value ->
      (value >>= field "intrinsicDefinitionChecks") == Just (Bool True))
