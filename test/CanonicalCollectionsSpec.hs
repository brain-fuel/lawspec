module CanonicalCollectionsSpec (test_canonicalCollections) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Core.Types (makeRegistry,keyedRequirements,equalityRequirements)
import LawSpec.Core.Verification (Verification(..),Layer(..))
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Model (Source(..),defaultGeneration,code)
import LawSpec.Testing (finiteCases, planTestingWith,Plan(..),PlannedUnit(..),PlannedProperty(..))
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import LawSpec.SourceText (formatSource)

compile bits text = compileCoreCanonical bits defaultGeneration [Source "canonical-sets.lawspec" text]
body text = compile 64 ("unit collections\n\n" ++ text ++ "\nend unit\n")

test_canonicalCollections = describe "canonical collections" $ do
  it "keeps ordered and equality-based collection models on their checked reference operations" $ do
    forM_ [("SortedSet","Int8","Set","setInsert"),("Set","Bool","EqSet","eqSetInsert")] $
      \(kind,element,internal,insert) -> do
        let source = unlines
              [ "type Storage is a record{marker :: Bool} end type\n"
              , "create :: Unit -> Storage"
              , "add :: Storage -> "++element++" -> Bool"
              , "remove :: Storage -> "++element++" -> Bool"
              , "contains :: Storage -> "++element++" -> Bool"
              , "model tags :: shared Storage behaves like "++kind++" "++element++" is"
              , "  start create"
              , "  add as add"
              , "  remove as remove"
              , "  contains as contains"
              , "end model" ]
        case body source of
          Left ds -> expectationFailure (show ds)
          Right program -> do
            length [machine | unit<-C.programUnits program,machine<-C.unitMachines unit] `shouldBe` 1
            map (C.idText . C.dataId) (C.programDataDeclarations program)
              `shouldContain` ["lawspec.collections::type::"++internal]
            let references = [definition | unit<-C.programUnits program,definition<-C.unitDefinitions unit,
                  C.declarationName (C.definitionDeclaration definition)=="tagsAddReference"]
                calls expression = case C.expressionNode expression of
                  C.ExternalCall identity arguments -> identity : concatMap calls arguments
                  _ -> concatMap calls (C.children expression)
                sources = [(C.declarationId declaration,C.declarationSource declaration) |
                  unit<-C.programUnits program,declaration<-C.unitDeclarations unit]
                calledSources = [original | identity<-concatMap (calls . C.definitionBody) references,
                  Just (Just original)<-[lookup identity sources]]
            references `shouldNotBe` []
            calledSources `shouldContain` [("lawspec.collections",insert)]
            case planTestingWith (Verification [Model]) program of
              Left ds -> expectationFailure (show ds)
              Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "emits ordered set matching without an unrelated map Entry declaration" $ do
    case body "function ordered (values :: SortedSet Integer) -> List Integer is prelude.toList values end function\n" of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        map (C.idText . C.dataId) (C.programDataDeclarations program)
          `shouldSatisfy` (\ids -> "lawspec.collections::type::Set" `elem` ids &&
            all (`notElem` ids) ["lawspec.collections::type::KeyVal","lawspec.collections::type::Entry"])
        case planTestingWith (Verification []) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "captures only the required Eq set provider despite bound values names" $ do
    let result = body "function selected (values :: List Float64) -> Set Float64 is setOf values end function\n"
    case result of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        map (C.idText . C.dataId) (C.programDataDeclarations program)
          `shouldSatisfy` (\ids -> "lawspec.collections::type::EqSet" `elem` ids &&
            all (`notElem` ids) ["lawspec.collections::type::Set","lawspec.collections::type::KeyVal","lawspec.collections::type::Entry","lawspec.collections::type::Ordering"])
        case planTestingWith (Verification []) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "retains authored declaration ownership through imports, re-exports and specialization" $ do
    let library = Source "spelling.lawspec" "unit spelling\n\nfunction same (value :: a) -> a is value end function\nend unit\n"
        facade = Source "facade.lawspec" "unit facade\nimport spelling as original\nexport original.same\nend unit\n"
        use = Source "use.lawspec" "unit use\nimport facade as copied\nlaw values is definition: copied.same true = true and copied.same 1 = 1 end definition end law\nend unit\n"
    case compileCoreCanonical 64 defaultGeneration [library,facade,use] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let declarations = [d | u <- C.programUnits program,d <- C.unitDeclarations u,
              C.declarationSource d == Just ("spelling","same")]
        length declarations `shouldBe` 2
        map C.declarationName declarations `shouldSatisfy` all (/= "same")
        forM_ declarations $ \d -> C.declarationOrigin d `shouldSatisfy` (\origin -> case origin of C.SourceSpan _ -> True; _ -> False)
  it "never derives declaration ownership from a compiler-looking user path or generated spelling" $ do
    let name = "lawspec_lawspecCollectionsEqSetOf_123"
        source = Source "<lawspec.collections>" ("unit lookalike\nfunction " ++ name ++ " (items :: List Bool) -> Set Bool is #S{false} end function\nend unit")
    case compileCoreCanonical 64 defaultGeneration [source] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let declarations = [d | u <- C.programUnits program,d <- C.unitDeclarations u,C.declarationName d == name]
        map C.declarationSource declarations `shouldBe` [Just ("lookalike",name)]
  it "checks finite membership and any through the shared checked element iteration" $ do
    source <- readFile "test/fixtures/canonical-collection-membership.lawspec"
    forM_ [32,64] $ \bits -> case compile bits source of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (Verification [Exhaustive,Examples]) program)
          `shouldBe` Right (replicate 20 ExhaustivelyChecked)
        case planTestingWith (Verification [Exhaustive,Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "requires Eq for generic membership while any needs only its predicate" $ do
    body "function includes (value :: a) (members :: List a) -> Bool is value in members end function\n" `shouldSatisfy` isLeft
    body "function includes (value :: a) (members :: List a) -> Bool requires Eq a is value in members end function\n" `shouldSatisfy` isRight
    body "function includes (value :: a) (members :: Queue a) -> Bool requires Eq a is value in members end function\n" `shouldSatisfy` isRight
    body "function same (value :: a) -> Bool is true end function\nfunction anyValue (members :: List a) -> Bool is prelude.any same members end function\n" `shouldSatisfy` isRight
  it "checks strict membership arguments and captured predicates even for empty collections" $ do
    body "function invalid (ignored :: Bool) -> Bool is prelude.member (1 / 0) ([] :: List Integer) end function\n" `shouldSatisfy` isLeft
    body "function exceeds (limit :: Integer) (value :: Integer) -> Bool is value > limit end function\nfunction invalid (ignored :: Bool) -> Bool is prelude.any (exceeds (1 / 0)) ([] :: List Integer) end function\n" `shouldSatisfy` isLeft
    body "function unsafe (value :: Integer) -> Bool is 1 / value > 0 end function\nfunction invalid (ignored :: Bool) -> Bool is prelude.any unsafe ([] :: List Integer) end function\n" `shouldSatisfy` isLeft
  it "takes literal collection element types from membership values and predicates" $ do
    body "function included (value :: Float64) -> Bool is value in [1.0, 2.0] end function\n" `shouldSatisfy` isRight
    body "function positive (value :: Float64) -> Bool is value > 0.0 end function\nfunction selected (unused :: Bool) -> Bool is prelude.any positive [1.0, 2.0] end function\n" `shouldSatisfy` isRight
    body "function included (value :: Float64) -> Bool is value in #S{1.0, 2.0} end function\n" `shouldSatisfy` isRight
    body "function invalid (value :: Decimal) (members :: List Float64) -> Bool is value in members end function\n" `shouldSatisfy` isLeft
    body "function exceeds (limit :: Float64) (value :: Float64) -> Bool is value > limit end function\nfunction selected (unused :: Bool) -> Bool is prelude.any (exceeds 1.0) [1.0, 2.0] end function\n" `shouldSatisfy` isRight
    body "function included (members :: List Float64) (value :: Float64) -> Bool is value in members end function\nfunction selected (unused :: Bool) -> Bool is prelude.any (included [1.0]) [1.0, 2.0] end function\n" `shouldSatisfy` isRight
    body "function same (value :: Float64) -> Float64 is value end function\nfunction exceeds (limit :: Float64) (value :: Float64) -> Bool is value > limit end function\nfunction selected (unused :: Bool) -> Bool is prelude.any ((exceeds 1.0) . same) [1.0, 2.0] end function\n" `shouldSatisfy` isRight
    body "function includes (members :: List a) (value :: a) -> Bool requires Eq a is value in members end function\nfunction selected (unused :: Bool) -> Bool is prelude.any ((includes [1.0]) :: Float64 -> Bool) [1.0, 2.0] end function\n" `shouldSatisfy` isRight
  it "keeps membership nonassociative and respects exact keyword boundaries" $ do
    body "function inside (insideValue :: Integer) -> Bool is insideValue in [1, 2] end function\n" `shouldSatisfy` isRight
    body "law invalid is definition: 1 in [1] in [true] end definition end law" `shouldSatisfy` isLeft
    body "law invalid is definition: 1 = in [1] end definition end law" `shouldSatisfy` isLeft
  it "ends let initializers at their own in while retaining membership in the body" $ do
    let source = "unit collections\nlaw bindings is definition: for all (value :: Bool) => " ++
          "let first = value in let second = not value in " ++
          "first in [value] and second in [not value] and first != second end let end let   end for all end definition end law\nend unit\n"
    forM_ [32,64] $ \bits -> case compile bits source of
      Left ds -> expectationFailure (show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (Verification [Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
  it "scopes the in delimiter through nested initializers and delimited membership expressions" $ do
    let initializers =
          [ "(value in [value])"
          , "let inner = value in (inner in [value]) end let"
          , "if value in [true] then true in [value] else false in [value] end if"
          , "first matching case of value: when true then true in [value] otherwise false in [value] end case"
          , "(record{present = value in [value]}).present"
          , "prelude.any affirmative [value in [value]]"
          , "prelude.any affirmative #S{value in [value]}" ]
    forM_ initializers $ \initializer -> case body
      ("function affirmative (value :: Bool) -> Bool is value end function\n" ++
       "law binding is definition: for all (value :: Bool) => let present = " ++
       initializer ++ " in present = true end let  end for all end definition end law\n") of
      Left ds -> expectationFailure (initializer ++ ": " ++ show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (Verification [Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
    body "law binding is definition: let outer = let inner = true in inner end let in outer = true end let end definition end law\n" `shouldSatisfy` isRight
  it "does not consume an enclosing let delimiter after closing a membership scope" $ do
    body "law invalid is definition: let present = (true in [true]) in end let end definition end law" `shouldSatisfy` isLeft
    body "function unsafe (value :: Integer) -> Integer is let divisor = value in 1 / divisor end let end function\n" `shouldSatisfy` isLeft
  it "requires explicit map selections and keeps substring matching separate" $ do
    forM_ ["prelude.member 1 (prelude.keyValOf [Entry 1 2])",
      "prelude.any affirmative (prelude.keyValOf [Entry false 1])",
      "prelude.member \"a\" \"abc\""] $ \expression ->
      body ("function affirmative (value :: Bool) -> Bool is value end function\nlaw invalid is definition: " ++ expression ++ " end definition end law\n") `shouldSatisfy` isLeft
  it "checks complete finite set domains without discarding stored iteration orders" $ do
    source <- readFile "test/fixtures/canonical-set-domains.lawspec"
    forM_ [32,64] $ \bits -> case compile bits source of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (Verification [Exhaustive,Examples]) program)
          `shouldBe` Right (replicate 8 ExhaustivelyChecked)
        case planTestingWith (Verification [Exhaustive,Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> do
            [length values | unit <- plannedUnits plan, property <- plannedProperties unit,
              Just values <- [finiteCases property]] `shouldBe` [5,1,25,17,114,1,2,16]
            forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "runs a complete singleton once without promoting planned property evidence" $ do
    source <- readFile "test/fixtures/canonical-set-domains.lawspec"
    case compile 64 source of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (Verification [Property,Examples]) program)
          `shouldBe` Right (replicate 8 Planned)
        case planTestingWith (Verification [Property,Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> [fmap length (finiteCases property) | unit <- plannedUnits plan,
            property <- plannedProperties unit] `shouldBe`
              [Nothing,Just 1,Nothing,Nothing,Nothing,Just 1,Nothing,Nothing]
  it "retains incomplete coverage for an unbounded floating set domain" $ do
    case body "law selected is definition: for all (members :: Set Float64) => prelude.size members >= 0 end for all end definition end law\n" of
      Left ds -> expectationFailure (show ds)
      Right program -> case planTestingWith (Verification [Exhaustive]) program of
        Left ds -> map code ds `shouldContain` ["verification-incomplete"]
        Right _ -> expectationFailure "an unbounded IEEE set domain became a complete cover"
  it "elaborates primitive set notation in expressions, records, alternatives, examples and tables" $ do
    source <- readFile "test/fixtures/canonical-set-literals.lawspec"
    forM_ [32,64] $ \bits -> case compile bits source of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let labels = [C.exampleName example | unit <- C.programUnits program,
              property <- C.unitProperties unit, example <- C.propertyExamples property]
        labels `shouldSatisfy` any ("#S{" `isInfixOf`)
        labels `shouldSatisfy` all (not . ("setOf" `isInfixOf`))
        -- Unbounded set inputs have examples, not complete finite coverage.
        case planTestingWith (Verification [Exhaustive,Examples]) program of
          Left ds -> map code ds `shouldContain` ["verification-incomplete"]
          Right _ -> expectationFailure "unbounded set domains were reported as complete"
        dischargeEvidenceWith (Verification [Examples]) program `shouldSatisfy` isRight
        case planTestingWith (Verification [Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
        let finite = program { C.programUnits =
              [u { C.unitProperties = filter (all ((== C.scalarType "Bool") . C.binderType . C.quantifiedBinder) . C.propertyInputs) (C.unitProperties u) }
              | u <- C.programUnits program] }
        dischargeEvidenceWith (Verification [Exhaustive]) finite `shouldSatisfy` isRight
        case planTestingWith (Verification [Exhaustive]) finite of
          Left ds -> expectationFailure (show ds)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "retains set notation and literal values during idempotent formatting" $ do
    source <- readFile "test/fixtures/canonical-set-literals.lawspec"
    let formatted = formatSource (Source "literal-format.lawspec" source)
    formatSource formatted `shouldBe` formatted
    compileCoreCanonical 64 defaultGeneration [formatted] `shouldSatisfy` isRight
  it "keeps set element restrictions and nominal boundaries checked" $ do
    body "function invalid (unused :: Bool) -> Set Nat is #S{0} end function\n" `shouldSatisfy` isLeft
    body "type Count is a record{value :: Integer} end type\nfunction invalid (unused :: Bool) -> Set Count is #S{1} end function\n" `shouldSatisfy` isLeft
    body "function values (unused :: Bool) -> Set Float64 is #S{1.0, 2.0} end function\n" `shouldSatisfy` isRight
    body "law values is definition: (prelude.setOf [float64Bits(\"3ff0000000000000\")]) = #S{1.0} end definition end law\n" `shouldSatisfy` isRight
  it "does not specialize computed values to a literal's expected element type" $
    body "function invalid (value :: Integer) -> Set Float64 is #S{value} end function\n" `shouldSatisfy` isLeft
  it "keeps checked exact arguments beside literal collection arguments" $ do
    let source = unlines
          [ "function keep (items :: List Integer) (value :: Int64) -> Int64 is value end function\n"
          , "function negative (unused :: Bool) -> Int64 is keep [] (0 - prelude.Int64 1) end function\n"
          , "law negativeValue is definition: for all (unused :: Bool) => negative unused = -1 end for all end definition end law" ]
    case body source of
      Left ds -> expectationFailure (show ds)
      Right program -> dischargeEvidenceWith (Verification [Exhaustive]) program `shouldSatisfy` isRight
  it "keeps Eq-only and ordered sets distinct in checked outcomes and every target" $ do
    source <- readFile "test/fixtures/canonical-sets.lawspec"
    forM_ [32,64] $ \bits -> case compile bits source of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        dischargeEvidenceWith (Verification [Exhaustive]) program `shouldSatisfy` isRight
        case planTestingWith (Verification [Exhaustive]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
        [(C.idText (C.dataId d),C.dataName d) | d <- C.programDataDeclarations program,
          C.idText (C.dataId d) `elem` ["lawspec.collections::type::EqSet","lawspec.collections::type::Set"]]
          `shouldMatchList` [("lawspec.collections::type::EqSet","Set"),("lawspec.collections::type::Set","SortedSet")]
  it "retains Eq-only capabilities and refuses an ordered Float64 construction" $ do
    body "function values (unused :: Bool) -> Set Float64 is prelude.setOf [1.0] end function\n" `shouldSatisfy` isRight
    body "function values (unused :: Bool) -> SortedSet Float64 is prelude.sortedSetOf [1.0] end function\n" `shouldSatisfy` isLeft
    body "function values (items :: List Decimal) -> Set Float64 is prelude.setOf items end function\n" `shouldSatisfy` isLeft
    body "function invalid (unused :: Bool) -> Set Nat is prelude.setOf [0] end function\n" `shouldSatisfy` isLeft
    case body "function same (set :: Set Float64) -> Set Float64 is set end function\n" of
      Left ds -> expectationFailure (show ds)
      Right program -> case makeRegistry (C.programDataDeclarations program) of
        Left message -> expectationFailure message
        Right registry -> do
          let ty=C.Constructor "lawspec.collections::type::EqSet" [C.TypeArgument (C.scalarType "Float64")]
          equalityRequirements registry ty `shouldBe` Right []
          keyedRequirements registry ty `shouldSatisfy` isLeft
  it "requires equality for membership and construction, but not iteration" $ do
    body "function includes (value :: a) (members :: Set a) -> Bool is prelude.member value members end function\n" `shouldSatisfy` isLeft
    body "function includes (value :: a) (members :: Set a) -> Bool requires Eq a is prelude.member value members end function\n" `shouldSatisfy` isRight
    body "function create (items :: List a) -> Set a is prelude.setOf items end function\n" `shouldSatisfy` isLeft
    body "function create (items :: List a) -> Set a requires Eq a is prelude.setOf items end function\n" `shouldSatisfy` isRight
    body "function read (members :: Set (a -> a)) -> List (a -> a) is prelude.toList members end function\n" `shouldSatisfy` isRight
  it "reserves compiler-owned unit identities without reserving arbitrary package names" $ do
    forM_ ["prelude", "lawspec.collections", "lawspec.time", "lawspec.resilience", "lawspec.matchers", "lawspec.resources", "lawspec.network", "lawspec.randomness", "lawspec.crypto", "lawspec.host", "lawspec.logging", "lawspec.concurrent"] $ \name ->
      case compile 64 ("unit " ++ name ++ "\nfunction same (value :: Bool) -> Bool is value end function\nend unit\n") of
        Left ds -> map code ds `shouldContain` ["reserved-unit"]
        Right _ -> expectationFailure ("user source replaced compiler-owned unit " ++ name)
    compile 64 "unit lawspec.customer\n\nfunction same (value :: Bool) -> Bool is value end function\nend unit\n" `shouldSatisfy` isRight
  it "hides both constructors and mutable representation fields" $ do
    forM_ ["c.EqSetItems []","c.SetItems []"] $ \expression ->
      body ("import lawspec.collections as c\nfunction invalid (unused :: Bool) -> Set Integer is "++expression++" end function") `shouldSatisfy` isLeft
    body "function invalid (set :: Set Integer) -> List Integer is set.items end function\n" `shouldSatisfy` isLeft
  it "preserves local and explicitly imported type names before the prelude" $ do
    body "type Set is a record{value :: Integer} end type\nfunction same (set :: Set) -> Set is set end function\n" `shouldSatisfy` isRight
    let own=Source "own.lawspec" "unit own\n\ntype Set is a record{value :: Integer} end type\nend unit\n"
        use=Source "use.lawspec" "unit use\nimport own as own (Set)\nfunction same (set :: Set) -> Set is set end function\nend unit\n"
    compileCoreCanonical 64 defaultGeneration [own,use] `shouldSatisfy` isRight
  it "uses the same namespace for qualified prefix and infix operations and re-exports" $ do
    body (unlines ["import lawspec.collections as c (Set)",
      "law calls is definition: c.setUnion (c.setOf [1]) (c.setOf [2]) = ((c.setOf [1]) `c.setUnion (c.setOf [2])) end definition end law"]) `shouldSatisfy` isRight
    let facade=Source "facade.lawspec" "unit facade\nimport lawspec.collections as c\nexport c.Set, c.SortedSet, c.setOf, c.sortedSetOf\nend unit\n"
        use=Source "use.lawspec" "unit use\nimport facade as c (Set, SortedSet)\nfunction values (unused :: Bool) -> Set Float64 is c.setOf [1.0] end function\nfunction ordered (unused :: Bool) -> SortedSet Integer is c.sortedSetOf [2, 1] end function\nend unit\n"
    compileCoreCanonical 64 defaultGeneration [facade,use] `shouldSatisfy` isRight
