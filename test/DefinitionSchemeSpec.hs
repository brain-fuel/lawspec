module DefinitionSchemeSpec (spec) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import LawSpec.Common
import LawSpec.Compile (validateDefinitionTypes, validateDefinitionTotality)
import LawSpec.Frontend (compileCore)
import LawSpec.Parser (parseSource)
import LawSpec.Refinement (lowerUnit)
import LawSpec.Data (qualifyDataNames, elaborateDataDeclarations)
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Eval as E
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Testing (planTesting)
import Control.Monad (forM_)

source :: String -> Source
source = Source "schemes.lawspec" . ("unit schemes\n" ++)

-- Test the template audit directly while source specialization is unfinished.
audit :: String -> Either String ()
audit = auditWith False

auditTotal :: String -> Either String ()
auditTotal = auditWith True

auditWith :: Bool -> String -> Either String ()
auditWith total = auditWithBits total 64

auditWithBits :: Bool -> Int -> String -> Either String ()
auditWithBits total bits body = do
  parsed <- either (Left . show) Right (parseSource (source body))
  unit <- qualifyDataNames <$> lowerUnit parsed
  declarations <- either (Left . show) Right (elaborateDataDeclarations [unit])
  either (Left . show) Right ((if total then validateDefinitionTotality else validateDefinitionTypes) declarations bits unit)

spec :: Spec
spec = describe "definition capabilities and template typing" $ do
  it "audits refined templates before specialization, including unused generic bodies" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
    auditRefined "definition reciprocal (x :: a where x != 0) :: Rational requires Integer a is 1 / x end"
      `shouldBe` Right ()
    auditRefined "definition reciprocal (x :: a where x >= 0) :: Rational requires Integer a is 1 / x end"
      `shouldSatisfy` isLeft
    auditRefined "definition next (x :: a where x >= 0) :: (result :: BigInt where result > x) requires Integer a is x + 1 end"
      `shouldBe` Right ()
    auditRefined "definition next (x :: a where x >= 0) :: (result :: BigInt where result < x) requires Integer a is x + 1 end"
      `shouldSatisfy` isLeft
  it "uses dependent definition parameters in contract proofs" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
    auditRefined "definition difference (x :: Int8) (y :: Int8 where y > x) :: Rational is 1 / (y - x) end"
      `shouldBe` Right ()
    auditRefined "definition next (x :: Int8 where x < 127) :: Int8 is prelude.Int8 (x + 1) end"
      `shouldBe` Right ()
    auditRefined "definition next (x :: Int8 where x <= 127) :: Int8 is prelude.Int8 (x + 1) end"
      `shouldSatisfy` isLeft
  it "checks refined template predicate scopes, types, and capabilities" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
    forM_ [
      "definition bad (x :: Int8 where y > x) (y :: Int8) :: Int8 is x end",
      "definition bad (x :: Int8 where result > 0) :: (result :: Int8) is x end",
      "definition bad (x :: Int8 where x + 1) :: Int8 is x end",
      "definition bad (x :: a where x > 0) :: a is x end",
      "definition bad (x :: Int8) :: (x :: Int8 where x > 0) is x end"] $ \body ->
        auditRefined body `shouldSatisfy` isLeft
  it "proves refined callees at template call sites and rejects cyclic contracts" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
        callee = "definition reciprocal (x :: a where x != 0) :: Rational requires Integer a is 1 / x end\n"
    auditRefined (callee ++ "definition caller (x :: Int8 where x > 0) :: Rational is reciprocal x end")
      `shouldBe` Right ()
    auditRefined (callee ++ "definition caller (x :: Int8) :: Rational is reciprocal x end")
      `shouldSatisfy` isLeft
    auditRefined "definition bad (x :: Int8 where bad x > 0) :: Int8 is x end"
      `shouldSatisfy` isLeft
  it "uses local primitive domains in nested and named matches without leaking facts" $ do
    auditTotal "definition first (xs :: List Int8) :: Rational is match xs with | Nil -> 0 | Cons head tail -> 1 / (head + 129) end end" `shouldBe` Right ()
    auditTotal "definition first (xs :: List Rational) :: Rational is match xs with | Nil -> 0 | Cons head tail -> 1 / (head + 129) end end" `shouldSatisfy` isLeft
    auditTotal "definition nested (xs :: List (List Int8)) :: Rational is match xs with | Nil -> 0 | Cons head tail -> match head with | Nil -> 0 | Cons value rest -> 1 / (value + 129) end end end" `shouldBe` Right ()
    let mixed = "type Mixed is Small value :: Int8 | Large value :: Int64 end\n"
    auditTotal (mixed ++ "definition safe (x :: Mixed) :: Rational is match x with | Small value -> 1 / (value + 129) | Large value -> 0 end end") `shouldBe` Right ()
    auditTotal (mixed ++ "definition unsafe (x :: Mixed) :: Rational is match x with | Small value -> 1 / (value + 129) | Large value -> 1 / (value + 129) end end") `shouldSatisfy` isLeft
  it "uses primitive domains and guarded integer conversion ranges" $ do
    auditTotal "definition shifted (x :: Int8) :: Rational is 1 / (x + 129) end" `shouldBe` Right ()
    auditTotal "definition shifted (x :: Int8) :: Rational is 1 / (x + 128) end" `shouldSatisfy` isLeft
    auditTotal "definition positive (x :: BigUInt) :: Rational is 1 / (x + 1) end" `shouldBe` Right ()
    auditTotal "definition positive (x :: BigInt) :: Rational is 1 / (x + 1) end" `shouldSatisfy` isLeft
    auditTotal "definition preserve (x :: Int8) :: Int8 is prelude.Int8 (x + 0) end" `shouldBe` Right ()
    auditTotal "definition overflow (x :: Int8) :: Int8 is prelude.Int8 (x + 1) end" `shouldSatisfy` isLeft
    auditTotal "definition next (x :: Int8) :: Bool is x < 127 && prelude.Int8 (x + 1) > x end" `shouldBe` Right ()
    auditTotal "definition narrow (x :: BigInt) :: Bool is x >= -128 && x <= 127 && prelude.Int8 x == x end" `shouldBe` Right ()
    auditTotal "definition fractional (x :: Rational) :: Bool is x >= -128 && x <= 127 && prelude.Int8 x == x end" `shouldSatisfy` isLeft
  it "uses the selected machine profile when proving conversions" $ do
    let body = "definition machine (x :: Int64) :: IntSize is prelude.IntSize x end"
    auditWithBits True 64 body `shouldBe` Right ()
    auditWithBits True 32 body `shouldSatisfy` isLeft
  it "proves nonzero exact denominators from affine and disjunctive guards" $ do
    auditTotal "definition guarded (x :: a) :: Bool requires Integer a is x >= 0 && 1 / (x + 1) > 0 end" `shouldBe` Right ()
    auditTotal "definition guarded (x :: a) :: Bool requires Integer a is (x < 0 || x > 0) && 1 / x == 1 / x end" `shouldBe` Right ()
    auditTotal "definition guarded (x :: a) (y :: a) :: Bool requires Integer a is x > y && 1 / (x - y) > 0 end" `shouldBe` Right ()
    auditTotal "definition guarded (x :: a) :: Bool requires Integer a is x >= 0 && 1 / x > 0 end" `shouldSatisfy` isLeft
    auditTotal "definition guarded (x :: a) :: Bool requires Integer a is x >= -1 && 1 / (x + 1) > 0 end" `shouldSatisfy` isLeft
    auditTotal "definition unsafe (x :: Float64) :: Bool is x != x && 1 / 0 == 0 end" `shouldSatisfy` isLeft
    auditTotal "definition unsafe (x :: Float64) :: Bool is x - x != 0 && 1 / 0 == 0 end" `shouldSatisfy` isLeft
  it "parses explicit definition requirements and retains their source span" $ do
    case parseSource (source "definition same (x :: a) (y :: a) :: Bool requires Eq a is x == y end") of
      Left ds -> expectationFailure (show ds)
      Right unit -> case S.functionDefinitions unit of
        [definition] -> do
          S.functionRequirements definition `shouldBe` [S.Capability "Eq" (S.Variable "a")]
          line (spanStart (S.functionSpan definition)) `shouldBe` 2
        other -> expectationFailure (show other)
  it "checks concrete capabilities on unused definitions" $ do
    compileCore 64 defaultGeneration [source
      "definition same (x :: Int8) (y :: Int8) :: Bool requires Eq Int8 is x == y end"]
      `shouldSatisfy` isRight
    compileCore 64 defaultGeneration [source
      "definition bad (x :: Text) :: Text requires Integer Text is x end"]
      `shouldSatisfy` isLeft
  it "checks equality requirements on rigid generic parameters" $ do
    audit "definition same (x :: a) (y :: a) :: Bool requires Eq a is x == y end" `shouldBe` Right ()
    audit "definition same (x :: a) (y :: a) :: Bool is x == y end" `shouldSatisfy` isLeft
    audit "definition same (x :: a) (y :: b) :: Bool requires Eq a Eq b is x == y end" `shouldSatisfy` isLeft
    audit "definition same (x :: a) (y :: b) :: Bool requires Integer a Integer b is x == y end" `shouldBe` Right ()
  it "checks integer promotion without specializing generic parameters" $ do
    audit "definition next (x :: a) :: BigInt requires Integer a is x + 1 end" `shouldBe` Right ()
    audit "definition next (x :: a) :: BigInt requires Eq a is x + 1 end" `shouldSatisfy` isLeft
    audit "definition next (x :: a) :: a requires Integer a is x + 1 end" `shouldSatisfy` isLeft
  it "does not assume unrelated ordered types have compatible numeric domains" $ do
    audit "definition less (x :: a) (y :: b) :: Bool requires Ordered a Ordered b is x < y end" `shouldSatisfy` isLeft
    audit "definition less (x :: a) (y :: a) :: Bool requires Ordered a is x < y end" `shouldBe` Right ()
    audit "definition positive (x :: a) :: Bool requires Ordered a is x > 0 end" `shouldBe` Right ()
  it "retains symbolic machine bounds until specialization" $ do
    audit "definition maximum (x :: a) :: BigInt requires Bounded a is a.max end" `shouldBe` Right ()
    audit "definition maximum (x :: a) :: BigInt is a.max end" `shouldSatisfy` isLeft
  it "checks generic recursive lists with exhaustive matching" $ do
    let header = "definition size (xs :: List a) :: BigInt is "
    audit (header ++ "match xs with | Nil -> 0 | Cons head tail -> 1 + size tail end end") `shouldBe` Right ()
    audit (header ++ "match xs with | Cons head tail -> 1 + size tail end end") `shouldSatisfy` isLeft
  it "rejects polymorphic recursive self-calls" $
    audit "definition loop (xs :: List a) :: BigInt is loop [xs] end" `shouldSatisfy` isLeft
  it "instantiates other definitions independently and propagates their requirements" $ do
    let identity = "definition identity (x :: a) :: a requires Eq a is x end\n"
    audit (identity ++ "definition both (x :: Unit) :: Bool is identity true && identity 1 == 1 end") `shouldBe` Right ()
    audit (identity ++ "definition caller (x :: a) :: a requires Eq a is identity x end") `shouldBe` Right ()
    audit (identity ++ "definition caller (x :: a) :: a is identity x end") `shouldSatisfy` isLeft
  it "preserves lexical parameter shadowing" $
    audit ("definition identity (x :: a) :: a is x end\n" ++
      "definition local (identity :: Bool) :: Bool is identity end") `shouldBe` Right ()
  it "derives structural equality requirements through named products" $ do
    let declaration = "type Pair (a :: Type) is Pair first :: a second :: Bool end\n"
        definition requirement = "definition same (x :: Pair a) (y :: Pair a) :: Bool " ++ requirement ++ "is x == y end"
    audit (declaration ++ definition "requires Eq a ") `shouldBe` Right ()
    audit (declaration ++ definition "") `shouldSatisfy` isLeft
  it "rejects unbound annotations and requirements" $ do
    audit "definition identity (x :: a) :: a requires Eq b is x end" `shouldSatisfy` isLeft
    audit "definition identity (x :: a) :: a is (x :: b) end" `shouldSatisfy` isLeft
  it "proves structural recursion on generic lists and promotes integer payloads" $
    auditTotal ("definition sum (xs :: List a) :: BigInt requires Integer a is " ++
      "match xs with | Nil -> 0 | Cons head tail -> head + sum tail end end") `shouldBe` Right ()
  it "proves structural recursion on named generic products and sums" $
    auditTotal ("type Tree (a :: Type) is Leaf value :: a | Branch left :: Tree a right :: Tree a end\n" ++
      "definition size (tree :: Tree a) :: BigInt is match tree with " ++
      "| Leaf value -> 1 | Branch left right -> size left + size right end end") `shouldBe` Right ()
  it "rejects generic recursion without structural descent" $ do
    auditTotal "definition loop (xs :: List a) :: BigInt is loop xs end" `shouldSatisfy` isLeft
    auditTotal ("definition loop (xs :: List a) :: BigInt is match xs with " ++
      "| Nil -> 0 | Cons head tail -> loop (Cons head tail) end end") `shouldSatisfy` isLeft
  it "requires one common decreasing parameter in generic recursion" $
    auditTotal ("definition loop (xs :: List a) (ys :: List a) :: BigInt is match xs with " ++
      "| Nil -> 0 | Cons head tail -> match ys with | Nil -> loop tail ys " ++
      "| Cons other rest -> loop xs rest end end end") `shouldSatisfy` isLeft
  it "does not confuse same-named binders from different match roots" $
    auditTotal ("definition loop (xs :: List a) (ys :: List a) :: BigInt is match xs with " ++
      "| Nil -> 0 | Cons head tail -> match ys with | Nil -> loop tail ys " ++
      "| Cons head tail -> loop tail ys end end end") `shouldSatisfy` isLeft
  it "requires nonzero guards for generic exact division and respects their order" $ do
    let definition expression = "definition divides (x :: a) (y :: a) :: Bool requires Integer a is " ++ expression ++ " end"
    auditTotal (definition "y != 0 && prelude.rem x y == 0") `shouldBe` Right ()
    auditTotal (definition "y == 0 || prelude.rem x y == 0") `shouldBe` Right ()
    auditTotal (definition "prelude.rem x y == 0 && y != 0") `shouldSatisfy` isLeft
    auditTotal (definition "y == 0 && prelude.rem x y == 0") `shouldSatisfy` isLeft
  it "checks generic presence guards" $ do
    let definition expression = "definition present (x :: Optional a) :: Bool requires Eq a is " ++ expression ++ " end"
        equality = "prelude.presentValue x == prelude.presentValue x"
    auditTotal (definition ("prelude.isPresent x && " ++ equality)) `shouldBe` Right ()
    auditTotal (definition equality) `shouldSatisfy` isLeft
  it "rejects potentially narrowing generic conversions" $ do
    auditTotal "definition widen (x :: a) :: BigInt requires Integer a is prelude.BigInt x end" `shouldBe` Right ()
    auditTotal "definition narrow (x :: a) :: Int8 requires Integer a is prelude.Int8 x end" `shouldSatisfy` isLeft
    auditTotal "definition decimal (x :: a) :: Decimal requires Integer a is prelude.Decimal x end" `shouldBe` Right ()
  it "checks decimal rounding scale conversions in template proofs" $ do
    auditTotal "definition rounded (x :: a) (scale :: Int32) :: Decimal requires Integer a is prelude.round x scale end" `shouldBe` Right ()
    auditTotal "definition rounded (x :: a) (scale :: BigInt) :: Decimal requires Integer a is prelude.round x scale end" `shouldSatisfy` isLeft
  it "uses the requested machine profile for conversion proofs" $ do
    let body = "definition machine (x :: Int64) :: IntSize is prelude.IntSize x end"
    auditWithBits True 32 body `shouldSatisfy` isLeft
    auditWithBits True 64 body `shouldBe` Right ()
    auditWithBits True 16 body `shouldSatisfy` isLeft
  it "audits closed dependencies even inside short-circuited branches" $ do
    auditTotal ("external :: Int8 -> Bool\n" ++
      "definition safe (x :: a) :: Bool is false && external 0 end") `shouldSatisfy` isLeft
    auditTotal "definition safe (x :: a) :: Bool is false && safe x end" `shouldBe` Right ()
  it "rejects mutually recursive generic definitions" $
    auditTotal ("definition first (xs :: List a) :: BigInt is second xs end\n" ++
      "definition second (xs :: List a) :: BigInt is first xs end") `shouldSatisfy` isLeft
  it "audits unused generic templates without inventing concrete instances" $ do
    case compileCore 64 defaultGeneration [source "definition identity (x :: a) :: a is x end"] of
      Left ds -> expectationFailure (show ds)
      Right program -> concatMap C.unitDefinitions (C.programUnits program) `shouldBe` []
    compileCore 64 defaultGeneration [source "definition loop (xs :: List a) :: BigInt is loop xs end"] `shouldSatisfy` isLeft
  it "executes bundled total-function examples and emits them for every target" $ do
    content <- readFile "examples/specs/total_functions.lawspec"
    forM_ [32, 64] $ \bits -> case compileCore bits defaultGeneration [Source "total_functions.lawspec" content] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        case (prepareDefinitions program, makeRegistry (C.programDataDeclarations program)) of
          (Right invoke, Right registry) -> forM_ (concatMap C.unitProperties (C.programUnits program)) $ \property ->
            forM_ (C.propertyExamples property) $ \example -> do
              let values = mapM (\(name, expression) -> (,) name <$>
                    E.evaluateValue registry bits invoke [] expression) (C.exampleBindings example)
              case values of
                Left message -> expectationFailure message
                Right bindings -> forM_ (C.exampleExpectations example) $ \expectation ->
                  E.evaluateValueProposition registry bits invoke bindings expectation `shouldBe` Right True
          other -> expectationFailure (case other of
            (Left ds, _) -> show ds
            (_, Left message) -> message
            _ -> "unreachable")
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
