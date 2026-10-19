-- | Capabilities and template typing of generic definitions.
module DefinitionSchemeSpec (test_definitionTemplatesAreAuditedBeforeSpecialization) where

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
source = Source "schemes.lawspec" . (\body -> "unit schemes\n" ++ body ++ "\nend unit\n")

-- | Test the template audit directly while source specialization is unfinished.
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

-- | A generic definition is used at many types, so its template must be audited
-- once, before specialization, or an unused instantiation could hide an unsafe
-- body. ref:DEC-total-definitions ref:REQ-definition-templates
test_definitionTemplatesAreAuditedBeforeSpecialization :: Spec
test_definitionTemplatesAreAuditedBeforeSpecialization = describe "definition capabilities and template typing" $ do
  it "audits refined templates before specialization, including unused generic bodies" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
    auditRefined "function reciprocal (x :: a where x != 0) -> Rational requires Integer a is 1 / x end function\n"
      `shouldBe` Right ()
    auditRefined "function reciprocal (x :: a where x >= 0) -> Rational requires Integer a is 1 / x end function\n"
      `shouldSatisfy` isLeft
    auditRefined "function next (x :: a where x >= 0) -> (result :: Integer where result > x) requires Integer a is x + 1 end function\n"
      `shouldBe` Right ()
    auditRefined "function next (x :: a where x >= 0) -> (result :: Integer where result < x) requires Integer a is x + 1 end function\n"
      `shouldSatisfy` isLeft
  it "uses dependent definition parameters in contract proofs" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
    auditRefined "function difference (x :: Int8) (y :: Int8 where y > x) -> Rational is 1 / (y - x) end function\n"
      `shouldBe` Right ()
    auditRefined "function next (x :: Int8 where x < 127) -> Int8 is prelude.Int8 (x + 1) end function\n"
      `shouldBe` Right ()
    auditRefined "function next (x :: Int8 where x <= 127) -> Int8 is prelude.Int8 (x + 1) end function\n"
      `shouldSatisfy` isLeft
  it "checks refined template predicate scopes, types, and capabilities" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
    forM_ [ "function bad (x :: Int8 where y > x) (y :: Int8) -> Int8 is x end function\n"
          , "function bad (x :: Int8 where result > 0) -> (result :: Int8) is x end function\n"
          , "function bad (x :: Int8 where x + 1) -> Int8 is x end function\n"
          , "function bad (x :: a where x > 0) -> a is x end function\n"
          , "function bad (x :: Int8) -> (x :: Int8 where x > 0) is x end function\n" ] $ \body ->
        auditRefined body `shouldSatisfy` isLeft
  it "proves refined callees at template call sites and rejects cyclic contracts" $ do
    let auditRefined body = do
          unit <- either (Left . show) Right (parseSource (source body))
          either (Left . show) Right (validateDefinitionTotality [] 64 unit)
        callee = "function reciprocal (x :: a where x != 0) -> Rational requires Integer a is 1 / x end function\n"
    auditRefined (callee ++ "function caller (x :: Int8 where x > 0) -> Rational is reciprocal x end function\n")
      `shouldBe` Right ()
    auditRefined (callee ++ "function caller (x :: Int8) -> Rational is reciprocal x end function\n")
      `shouldSatisfy` isLeft
    auditRefined "function bad (x :: Int8 where bad x > 0) -> Int8 is x end function\n"
      `shouldSatisfy` isLeft
  it "uses local primitive domains in nested and named matches without leaking facts" $ do
    auditTotal "function first (xs :: List Int8) -> Rational is first matching case of xs : when Nil then 0 when Cons head tail then 1 / (head + 129) end case end function\n" `shouldBe` Right ()
    auditTotal "function first (xs :: List Rational) -> Rational is first matching case of xs : when Nil then 0 when Cons head tail then 1 / (head + 129) end case end function\n" `shouldSatisfy` isLeft
    auditTotal "function nested (xs :: List (List Int8)) -> Rational is first matching case of xs : when Nil then 0 when Cons head tail then first matching case of head : when Nil then 0 when Cons value rest then 1 / (value + 129) end case end case end function\n" `shouldBe` Right ()
    let mixed = "type Mixed is one of Small  of type Int8 | Large  of type Int64 end type\n"
    auditTotal (mixed ++ "function safe (x :: Mixed) -> Rational is first matching case of x : when Small value then 1 / (value + 129) when Large value then 0 end case end function\n") `shouldBe` Right ()
    auditTotal (mixed ++ "function unsafe (x :: Mixed) -> Rational is first matching case of x : when Small value then 1 / (value + 129) when Large value then 1 / (value + 129) end case end function\n") `shouldSatisfy` isLeft
  it "uses primitive domains and guarded integer conversion ranges" $ do
    auditTotal "function shifted (x :: Int8) -> Rational is 1 / (x + 129) end function\n" `shouldBe` Right ()
    auditTotal "function shifted (x :: Int8) -> Rational is 1 / (x + 128) end function\n" `shouldSatisfy` isLeft
    auditTotal "function positive (x :: Whole) -> Rational is 1 / (x + 1) end function\n" `shouldBe` Right ()
    auditTotal "function positive (x :: Integer) -> Rational is 1 / (x + 1) end function\n" `shouldSatisfy` isLeft
    auditTotal "function preserve (x :: Int8) -> Int8 is prelude.Int8 (x + 0) end function\n" `shouldBe` Right ()
    auditTotal "function overflow (x :: Int8) -> Int8 is prelude.Int8 (x + 1) end function\n" `shouldSatisfy` isLeft
    auditTotal "function next (x :: Int8) -> Bool is x < 127 && prelude.Int8 (x + 1) > x end function\n" `shouldBe` Right ()
    auditTotal "function narrow (x :: Integer) -> Bool is x >= -128 && x <= 127 && prelude.Int8 x = x end function\n" `shouldBe` Right ()
    auditTotal "function fractional (x :: Rational) -> Bool is x >= -128 && x <= 127 && prelude.Int8 x = x end function\n" `shouldSatisfy` isLeft
  it "uses the selected machine profile when proving conversions" $ do
    let body = "function machine (x :: Int64) -> IntSize is prelude.IntSize x end function\n"
    auditWithBits True 64 body `shouldBe` Right ()
    auditWithBits True 32 body `shouldSatisfy` isLeft
  it "proves nonzero exact denominators from affine and disjunctive guards" $ do
    auditTotal "function guarded (x :: a) -> Bool requires Integer a is x >= 0 && 1 / (x + 1) > 0 end function\n" `shouldBe` Right ()
    auditTotal "function guarded (x :: a) -> Bool requires Integer a is (x < 0 || x > 0) && 1 / x = 1 / x end function\n" `shouldBe` Right ()
    auditTotal "function guarded (x :: a) (y :: a) -> Bool requires Integer a is x > y && 1 / (x - y) > 0 end function\n" `shouldBe` Right ()
    auditTotal "function guarded (x :: a) -> Bool requires Integer a is x >= 0 && 1 / x > 0 end function\n" `shouldSatisfy` isLeft
    auditTotal "function guarded (x :: a) -> Bool requires Integer a is x >= -1 && 1 / (x + 1) > 0 end function\n" `shouldSatisfy` isLeft
    auditTotal "function unsafe (x :: Float64) -> Bool is x != x && 1 / 0 = 0 end function\n" `shouldSatisfy` isLeft
    auditTotal "function unsafe (x :: Float64) -> Bool is x - x != 0 && 1 / 0 = 0 end function\n" `shouldSatisfy` isLeft
  it "parses explicit definition requirements and retains their source span" $ do
    case parseSource (source "function same (x :: a) (y :: a) -> Bool requires Eq a is x = y end function\n") of
      Left ds -> expectationFailure (show ds)
      Right unit -> case S.functionDefinitions unit of
        [definition] -> do
          S.functionRequirements definition `shouldBe` [S.Capability "Eq" (S.Variable "a")]
          line (spanStart (S.functionSpan definition)) `shouldBe` 2
        other -> expectationFailure (show other)
  it "checks concrete capabilities on unused definitions" $ do
    compileCore 64 defaultGeneration [source
      "function same (x :: Int8) (y :: Int8) -> Bool requires Eq Int8 is x = y end function\n"]
      `shouldSatisfy` isRight
    compileCore 64 defaultGeneration [source
      "function bad (x :: Text) -> Text requires Integer Text is x end function\n"]
      `shouldSatisfy` isLeft
  it "checks equality requirements on rigid generic parameters" $ do
    audit "function same (x :: a) (y :: a) -> Bool requires Eq a is x = y end function\n" `shouldBe` Right ()
    audit "function same (x :: a) (y :: a) -> Bool is x = y end function\n" `shouldSatisfy` isLeft
    audit "function same (x :: a) (y :: b) -> Bool requires Eq a Eq b is x = y end function\n" `shouldSatisfy` isLeft
    audit "function same (x :: a) (y :: b) -> Bool requires Integer a Integer b is x = y end function\n" `shouldBe` Right ()
  it "checks integer promotion without specializing generic parameters" $ do
    audit "function next (x :: a) -> Integer requires Integer a is x + 1 end function\n" `shouldBe` Right ()
    audit "function next (x :: a) -> Integer requires Eq a is x + 1 end function\n" `shouldSatisfy` isLeft
    audit "function next (x :: a) -> a requires Integer a is x + 1 end function\n" `shouldSatisfy` isLeft
  it "does not assume unrelated ordered types have compatible numeric domains" $ do
    audit "function less (x :: a) (y :: b) -> Bool requires Ordered a Ordered b is x < y end function\n" `shouldSatisfy` isLeft
    audit "function less (x :: a) (y :: a) -> Bool requires Ordered a is x < y end function\n" `shouldBe` Right ()
    audit "function positive (x :: a) -> Bool requires Ordered a is x > 0 end function\n" `shouldBe` Right ()
  it "retains symbolic machine bounds until specialization" $ do
    audit "function maximum (x :: a) -> Integer requires Bounded a is a.max end function\n" `shouldBe` Right ()
    audit "function maximum (x :: a) -> Integer is a.max end function\n" `shouldSatisfy` isLeft
  it "checks generic recursive lists with exhaustive matching" $ do
    let header = "function size (xs :: List a) -> Integer is "
    audit (header ++ "first matching case of xs: when Nil then 0 when Cons head tail then 1 + size tail end case end function") `shouldBe` Right ()
    audit (header ++ "first matching case of xs: when Cons head tail then 1 + size tail end case end function") `shouldSatisfy` isLeft
  -- Polymorphic recursion type-checks; totality still needs a decrease.
  it "accepts polymorphic recursive self-calls but not as total" $ do
    audit "function loop (xs :: List a) -> Integer is loop [xs] end function\n" `shouldBe` Right ()
    auditTotal "function loop (xs :: List a) -> Integer is loop [xs] end function\n" `shouldSatisfy` isLeft
  it "instantiates other definitions independently and propagates their requirements" $ do
    let identity = "function identity (x :: a) -> a requires Eq a is x end function\n"
    audit (identity ++ "function both (x :: Unit) -> Bool is identity true && identity 1 = 1 end function\n") `shouldBe` Right ()
    audit (identity ++ "function caller (x :: a) -> a requires Eq a is identity x end function\n") `shouldBe` Right ()
    audit (identity ++ "function caller (x :: a) -> a is identity x end function\n") `shouldSatisfy` isLeft
  it "preserves lexical parameter shadowing" $
    audit ("function identity (x :: a) -> a is x end function\n" ++
      "function local (identity :: Bool) -> Bool is identity end function\n") `shouldBe` Right ()
  it "derives structural equality requirements through named products" $ do
    let declaration = "type Pair (a :: Type) is a record{  first :: a second :: Bool} end type\n"
        definition requirement = "function same (x :: Pair a) (y :: Pair a) -> Bool " ++ requirement ++ "is x = y end function"
    audit (declaration ++ definition "requires Eq a ") `shouldBe` Right ()
    audit (declaration ++ definition "") `shouldSatisfy` isLeft
  it "rejects unbound annotations and requirements" $ do
    audit "function identity (x :: a) -> a requires Eq b is x end function\n" `shouldSatisfy` isLeft
    audit "function identity (x :: a) -> a is (x :: b) end function\n" `shouldSatisfy` isLeft
  it "proves structural recursion on generic lists and promotes integer payloads" $
    auditTotal ("function sum (xs :: List a) -> Integer requires Integer a is " ++
      "first matching case of xs : when Nil then 0 when Cons head tail then head + sum tail end case end function\n") `shouldBe` Right ()
  it "proves structural recursion on named generic products and sums" $
    auditTotal ("type Tree (a :: Type) is one of Leaf  of type a | Branch of type record{ left :: Tree a right :: Tree a} end type\n" ++
      "function size (tree :: Tree a) -> Integer is first matching case of tree: " ++
      "when Leaf value then 1 when Branch record{left = left, right = right} then size left + size right end case end function") `shouldBe` Right ()
  it "rejects generic recursion without structural descent" $ do
    auditTotal "function loop (xs :: List a) -> Integer is loop xs end function\n" `shouldSatisfy` isLeft
    auditTotal ("function loop (xs :: List a) -> Integer is first matching case of xs: " ++
      "when Nil then 0 when Cons head tail then loop (Cons head tail) end case end function") `shouldSatisfy` isLeft
  it "requires one common decreasing parameter in generic recursion" $
    auditTotal ("function loop (xs :: List a) (ys :: List a) -> Integer is first matching case of xs: " ++
      "when Nil then 0 when Cons head tail then first matching case of ys: when Nil then loop tail ys " ++
      "when Cons other rest then loop xs rest end case end case end function") `shouldSatisfy` isLeft
  it "does not confuse same-named binders from different match roots" $
    auditTotal ("function loop (xs :: List a) (ys :: List a) -> Integer is first matching case of xs: " ++
      "when Nil then 0 when Cons head tail then first matching case of ys: when Nil then loop tail ys " ++
      "when Cons head tail then loop tail ys end case end case end function") `shouldSatisfy` isLeft
  it "requires nonzero guards for generic exact division and respects their order" $ do
    let definition expression = "function divides (x :: a) (y :: a) -> Bool requires Integer a is " ++ expression ++ " end function\n"
    auditTotal (definition "y != 0 && prelude.rem x y == 0") `shouldBe` Right ()
    auditTotal (definition "y == 0 || prelude.rem x y == 0") `shouldBe` Right ()
    auditTotal (definition "prelude.rem x y == 0 && y != 0") `shouldSatisfy` isLeft
    auditTotal (definition "y == 0 && prelude.rem x y == 0") `shouldSatisfy` isLeft
  it "checks generic presence guards" $ do
    let definition expression = "function present (x :: Optional a) -> Bool requires Eq a is " ++ expression ++ " end function\n"
        equality = "prelude.presentValue x == prelude.presentValue x"
    auditTotal (definition ("prelude.isPresent x && " ++ equality)) `shouldBe` Right ()
    auditTotal (definition equality) `shouldSatisfy` isLeft
  it "rejects potentially narrowing generic conversions" $ do
    auditTotal "function widen (x :: a) -> Integer requires Integer a is prelude.BigInt x end function\n" `shouldBe` Right ()
    auditTotal "function narrow (x :: a) -> Int8 requires Integer a is prelude.Int8 x end function\n" `shouldSatisfy` isLeft
    auditTotal "function decimal (x :: a) -> Decimal requires Integer a is prelude.Decimal x end function\n" `shouldBe` Right ()
  it "checks decimal rounding scale conversions in template proofs" $ do
    auditTotal "function rounded (x :: a) (scale :: Int32) -> Decimal requires Integer a is prelude.round x scale end function\n" `shouldBe` Right ()
    auditTotal "function rounded (x :: a) (scale :: Integer) -> Decimal requires Integer a is prelude.round x scale end function\n" `shouldSatisfy` isLeft
  it "uses the requested machine profile for conversion proofs" $ do
    let body = "function machine (x :: Int64) -> IntSize is prelude.IntSize x end function\n"
    auditWithBits True 32 body `shouldSatisfy` isLeft
    auditWithBits True 64 body `shouldBe` Right ()
    auditWithBits True 16 body `shouldSatisfy` isLeft
  it "audits closed dependencies even inside short-circuited branches" $ do
    auditTotal ("external :: Int8 -> Bool\n" ++
      "function safe (x :: a) -> Bool is false && external 0 end function\n") `shouldSatisfy` isLeft
    auditTotal "function safe (x :: a) -> Bool is false && safe x end function\n" `shouldBe` Right ()
  it "rejects mutually recursive generic definitions" $
    auditTotal ("function first (xs :: List a) -> Integer is second xs end function\n" ++
      "function second (xs :: List a) -> Integer is first xs end function\n") `shouldSatisfy` isLeft
  it "audits unused generic templates without inventing concrete instances" $ do
    case compileCore 64 defaultGeneration [source "function identity (x :: a) -> a is x end function\n"] of
      Left ds -> expectationFailure (show ds)
      Right program -> concatMap C.unitDefinitions (C.programUnits program) `shouldBe` []
    compileCore 64 defaultGeneration [source "function loop (xs :: List a) -> Integer is loop xs end function\n"] `shouldSatisfy` isLeft
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
