-- | Finite cases may be compressed without changing execution or coverage.
-- ref:DEC-planned-generation
module FiniteCoverSpec (test_finiteCoversPreserveEveryOrderedCase) where

import LawSpec.Core.Value (Value(..))
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Value as Value
import qualified LawSpec.Testing.Literals as L
import qualified Control.Monad.State.Strict as S
import Data.List (intersect)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Testing.Cover
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

integer :: Integer -> Value
integer = ScalarValue . SInteger "Int8"

boolean :: Bool -> Value
boolean = ScalarValue . SBool

test_finiteCoversPreserveEveryOrderedCase :: Spec
test_finiteCoversPreserveEveryOrderedCase = describe "ordered finite covers" $ do
  it "shares literal code while retaining ordered nested values, witnesses and repeated roots" $ do
    let bool = C.scalarType "Bool"
        inner = Value.listValue bool [boolean True, boolean False]
        outer = Value.listValue (Value.valueType inner) [inner, inner]
        packed = DataValue (C.Constructor "Packed" []) (C.Id "Packed::Pack")
          [outer, ScalarValue (SSymbol "id" "name"), ScalarValue (SSequence "Text" [65])]
        roots = [packed, packed, outer, inner]
    plan <- either expectationFailure' pure (L.planLiterals roots)
    L.literalFactories plan `shouldSatisfy` (not . null)
    mapM (\value -> L.literalReference plan value >>= materialize plan) roots `shouldBe` Right roots
    -- Independent dependency ordering permits ordinary, non-recursive helper
    -- declarations in every target, without changing value evaluation order.
    mapM_ (\(index, body) -> sharedReferences body `shouldSatisfy` all (< index)) (L.literalFactories plan)
  it "executes a shared literal factory afresh for each invocation" $ do
    let value = Value.listValue (C.scalarType "Bool") [boolean True, boolean False]
    plan <- either expectationFailure' pure (L.planLiterals [value,value])
    root <- either expectationFailure' pure (L.literalReference plan value)
    let allocate :: L.LiteralTerm -> S.State Int [Int]
        allocate body = L.foldLiteral (const (pure []))
          (\_ fields -> do
            next <- S.get
            S.put (next + 1)
            pure (next : concat fields))
          (\index -> maybe (error "missing literal factory") allocate (lookup index (L.literalFactories plan))) body
        (first, next) = S.runState (allocate root) (0 :: Int)
        (second, _) = S.runState (allocate root) next
    first `shouldSatisfy` (not . null)
    first `intersect` second `shouldBe` []
  it "rejects malformed list data instead of truncating its literal table" $ do
    let malformed = DataValue (C.Constructor "List" [C.TypeArgument (C.scalarType "Bool")]) (C.Id "List::Cons") [boolean True]
    L.planLiterals [malformed] `shouldBe` Left "invalid List constructor or tail"
  it "stores a Cartesian domain once, using an inclusive integer interval" $ do
    let rows = [[boolean b, integer n] | b <- [False, True], n <- [-128 .. 127]]
        expected = Alternatives [(Values [boolean False, boolean True],
          Alternatives [(IntegerInterval "Int8" (-128) 127, Complete 1)])]
    compressCases rows `shouldBe` Right expected
    coverCases expected `shouldBe` rows
    coverCount expected `shouldBe` 512
  it "preserves dependent prefixes instead of filling in missing combinations" $ do
    let rows = [[integer a, integer b] | a <- [0 .. 4], b <- [0 .. a]]
    case compressCases rows of
      Left message -> expectationFailure message
      Right cover -> do
        coverCases cover `shouldBe` rows
        coverCount cover `shouldBe` 15
  it "preserves duplicates and nonadjacent alternatives in execution order" $ do
    let rows = [[integer 2, boolean True], [integer 2, boolean True],
                [integer 1, boolean False], [integer 2, boolean True]]
    fmap coverCases (compressCases rows) `shouldBe` Right rows
  it "distinguishes an empty domain from one case without inputs" $ do
    fmap coverCount (compressCases []) `shouldBe` Right 0
    fmap coverCases (compressCases [[]]) `shouldBe` Right [[]]
    fmap coverCount (compressCases [[], []]) `shouldBe` Right 2
  it "rejects cases with inconsistent arity" $
    compressCases [[], [integer 0]] `shouldBe` Left "finite cover cases have different arities"
  it "does not turn a sparse domain into an integer interval" $
    compressCases [[integer n] | n <- [0, 1, 3]] `shouldBe`
      Right (Alternatives [(Values (map integer [0, 1, 3]), Complete 1)])
  it "counts large intervals without enumerating their values" $ do
    let count = 2 ^ (128 :: Int)
    coverCount (Alternatives [(IntegerInterval "BigUInt" 0 (count - 1), Complete 1)]) `shouldBe` count
  it "preserves every small ordered observation sequence" $ do
    let alphabet = [[boolean a, boolean b] | a <- [False, True], b <- [False, True]]
        observations = concat [sequence (replicate count alphabet) | count <- [0 .. 4]]
    mapM_ (\rows -> fmap coverCases (compressCases rows) `shouldBe` Right rows) observations
  it "agrees with the JavaScript runtime, including lazy and fresh values" $ do
    (code, out, err) <- readProcessWithExitCode "node" ["test/finite-cases.mjs"] ""
    (code, err) `shouldBe` (ExitSuccess, "")
    out `shouldContain` "conformance passed"
  it "agrees with Python runtime registration and individual case selection" $ do
    (code, out, err) <- readProcessWithExitCode "python3" ["test/finite_cases.py"] ""
    (code, err) `shouldBe` (ExitSuccess, "")
    out `shouldContain` "conformance passed"

expectationFailure' :: String -> IO a
expectationFailure' message = expectationFailure message >> fail message

sharedReferences :: L.LiteralTerm -> [Int]
sharedReferences (L.ScalarLiteral _) = []
sharedReferences (L.ApplyLiteral _ fields) = concatMap sharedReferences fields
sharedReferences (L.SharedLiteral index) = [index]

materialize :: L.LiteralPlan -> L.LiteralTerm -> Either String Value
materialize plan = L.foldLiteral (pure . ScalarValue) shape shared
  where
    shape index fields = case lookup index (L.literalShapes plan) of
      Just (L.ConstructorShape ty tag) -> pure (DataValue ty tag fields)
      Just (L.ListShape (C.Constructor "List" [C.TypeArgument element])) -> pure (Value.listValue element fields)
      Just (L.PresenceShape ty False) | null fields -> pure (PresenceValue ty Nothing)
      Just (L.PresenceShape ty True) | [value] <- fields -> pure (PresenceValue ty (Just value))
      _ -> Left "invalid literal shape"
    shared index = maybe (Left "missing literal factory") (materialize plan) (lookup index (L.literalFactories plan))
