-- | Finite cases may be compressed without changing execution or coverage.
-- ref:DEC-planned-generation
module FiniteCoverSpec (test_finiteCoversPreserveEveryOrderedCase) where

import LawSpec.Core.Value (Value(..))
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
