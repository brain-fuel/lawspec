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
import LawSpec.Testing (planTestingWith)
import LawSpec.SourceText (formatSource)

compile bits text = compileCoreCanonical bits defaultGeneration [Source "canonical-sets.lawspec" text]
body text = compile 64 ("unit collections\n" ++ text)

test_canonicalCollections = describe "canonical collections" $ do
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
    body "function invalid (unused :: Bool) -> Set Nat is #S{0} end function" `shouldSatisfy` isLeft
    body "type Count is a record{value :: Integer} end type\nfunction invalid (unused :: Bool) -> Set Count is #S{1} end function" `shouldSatisfy` isLeft
    body "function values (unused :: Bool) -> Set Float64 is #S{1.0, 2.0} end function" `shouldSatisfy` isRight
    body "law values is definition: (prelude.setOf [float64Bits(\"3ff0000000000000\")]) = #S{1.0} end end" `shouldSatisfy` isRight
  it "does not specialize computed values to a literal's expected element type" $
    body "function invalid (value :: Integer) -> Set Float64 is #S{value} end function" `shouldSatisfy` isLeft
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
    body "function values (unused :: Bool) -> Set Float64 is prelude.setOf [1.0] end function" `shouldSatisfy` isRight
    body "function values (unused :: Bool) -> SortedSet Float64 is prelude.sortedSetOf [1.0] end function" `shouldSatisfy` isLeft
    body "function values (items :: List Decimal) -> Set Float64 is prelude.setOf items end function" `shouldSatisfy` isLeft
    body "function invalid (unused :: Bool) -> Set Nat is prelude.setOf [0] end function" `shouldSatisfy` isLeft
    case body "function same (set :: Set Float64) -> Set Float64 is set end function" of
      Left ds -> expectationFailure (show ds)
      Right program -> case makeRegistry (C.programDataDeclarations program) of
        Left message -> expectationFailure message
        Right registry -> do
          let ty=C.Constructor "lawspec.collections::type::EqSet" [C.TypeArgument (C.scalarType "Float64")]
          equalityRequirements registry ty `shouldBe` Right []
          keyedRequirements registry ty `shouldSatisfy` isLeft
  it "requires equality for membership and construction, but not iteration" $ do
    body "function includes (value :: a) (members :: Set a) -> Bool is prelude.member value members end function" `shouldSatisfy` isLeft
    body "function includes (value :: a) (members :: Set a) -> Bool requires Eq a is prelude.member value members end function" `shouldSatisfy` isRight
    body "function create (items :: List a) -> Set a is prelude.setOf items end function" `shouldSatisfy` isLeft
    body "function create (items :: List a) -> Set a requires Eq a is prelude.setOf items end function" `shouldSatisfy` isRight
    body "function read (members :: Set (a -> a)) -> List (a -> a) is prelude.toList members end function" `shouldSatisfy` isRight
  it "reserves compiler-owned unit identities without reserving arbitrary package names" $ do
    forM_ ["prelude", "lawspec.collections", "lawspec.time", "lawspec.resilience", "lawspec.matchers", "lawspec.resources", "lawspec.network", "lawspec.randomness", "lawspec.crypto", "lawspec.host", "lawspec.logging", "lawspec.concurrent"] $ \name ->
      case compile 64 ("unit " ++ name ++ "\nfunction same (value :: Bool) -> Bool is value end function") of
        Left ds -> map code ds `shouldContain` ["reserved-unit"]
        Right _ -> expectationFailure ("user source replaced compiler-owned unit " ++ name)
    compile 64 "unit lawspec.customer\nfunction same (value :: Bool) -> Bool is value end function" `shouldSatisfy` isRight
  it "hides both constructors and mutable representation fields" $ do
    forM_ ["c.EqSetItems []","c.SetItems []"] $ \expression ->
      body ("import lawspec.collections as c\nfunction invalid (unused :: Bool) -> Set Integer is "++expression++" end function") `shouldSatisfy` isLeft
    body "function invalid (set :: Set Integer) -> List Integer is set.items end function" `shouldSatisfy` isLeft
  it "preserves local and explicitly imported type names before the prelude" $ do
    body "type Set is a record{value :: Integer} end type\nfunction same (set :: Set) -> Set is set end function" `shouldSatisfy` isRight
    let own=Source "own.lawspec" "unit own\ntype Set is a record{value :: Integer} end type"
        use=Source "use.lawspec" "unit use\nimport own as own (Set)\nfunction same (set :: Set) -> Set is set end function"
    compileCoreCanonical 64 defaultGeneration [own,use] `shouldSatisfy` isRight
  it "uses the same namespace for qualified prefix and infix operations and re-exports" $ do
    body (unlines ["import lawspec.collections as c (Set)",
      "law calls is definition: c.setUnion (c.setOf [1]) (c.setOf [2]) = ((c.setOf [1]) `c.setUnion (c.setOf [2])) end end"]) `shouldSatisfy` isRight
    let facade=Source "facade.lawspec" "unit facade\nimport lawspec.collections as c\nexport c.Set, c.SortedSet, c.setOf, c.sortedSetOf"
        use=Source "use.lawspec" "unit use\nimport facade as c (Set, SortedSet)\nfunction values (unused :: Bool) -> Set Float64 is c.setOf [1.0] end function\nfunction ordered (unused :: Bool) -> SortedSet Integer is c.sortedSetOf [2, 1] end function"
    compileCoreCanonical 64 defaultGeneration [facade,use] `shouldSatisfy` isRight
