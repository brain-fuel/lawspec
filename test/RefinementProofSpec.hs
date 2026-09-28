module RefinementProofSpec (spec) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Ratio ((%))
import qualified Data.Map.Strict as M
import LawSpec.Core (Id(..))
import LawSpec.Core.RefinementProof

x, y, zero :: Linear
x = variable (Id "x")
y = variable (Id "y")
zero = constant 0

check :: [Predicate] -> Predicate -> Verdict
check = prove 100000

spec :: Spec
spec = describe "exact refinement implication" $ do
  it "normalizes exact arithmetic without ambient rounding" $ do
    check [] (Compare EqualTo (plus (constant (1 % 10)) (constant (1 % 5)))
      (constant (3 % 10))) `shouldBe` Proven
    check [] (Compare EqualTo (plus x y) (plus y x)) `shouldBe` Proven
    check [] (Compare EqualTo (plus x (scale (-1) x)) zero) `shouldBe` Proven
    forM_ [(a,b) | a <- [-2, -1 % 3, 0, 7], b <- [-5, 0, 2 % 7]] $ \(a,b) ->
      evaluateLinear (M.fromList [(Id "x",a),(Id "y",b)])
        (plus (constant (1 % 10)) (plus (scale 3 x) (scale (-2) y)))
        `shouldBe` Just (1 % 10 + 3 * a - 2 * b)
  it "keeps strict and inclusive boundaries distinct" $ do
    check [Compare GreaterThan x zero] (Compare NotEqualTo x zero) `shouldBe` Proven
    check [Compare AtLeast x zero] (Compare NotEqualTo x zero) `shouldBe` Unknown
    check [Compare AtLeast x zero, Compare AtMost x zero] (Compare EqualTo x zero) `shouldBe` Proven
    check [Compare LessThan x y] (Compare AtMost x y) `shouldBe` Proven
    check [Compare AtMost x y] (Compare LessThan x y) `shouldBe` Unknown
  it "proves bounds on promoted sums through several variables" $ do
    let z = variable (Id "z")
    check [Compare AtMost x y, Compare LessThan y z]
      (Compare LessThan x z) `shouldBe` Proven
    check [Compare AtMost x (constant 127), Compare AtMost y (constant 127)]
      (Compare AtMost (plus x y) (constant 254)) `shouldBe` Proven
    check [Compare AtMost x (constant 127), Compare AtMost y (constant 127)]
      (Compare AtMost (plus x y) (constant 127)) `shouldBe` Unknown
  it "proves checked narrowing only when the input bounds suffice" $ do
    let domain = [Compare AtLeast x (constant (-128)), Compare AtMost x (constant 127)]
        narrowed = All [Compare AtLeast (plus x (constant 1)) (constant (-128)),
          Compare AtMost (plus x (constant 1)) (constant 127)]
    check domain narrowed `shouldBe` Unknown
    check (Compare AtMost x (constant 126) : domain) narrowed `shouldBe` Proven
    check [Compare AtLeast x zero, Compare AtMost x (constant 255)]
      (Compare AtMost x (constant 127)) `shouldBe` Unknown
  it "checks both machine-width integer bounds exactly" $
    forM_ [32,64 :: Int] $ \bits -> do
      let limit = 2 ^ (bits - 1)
      check [Compare AtLeast x (constant (-limit)), Compare AtMost x (constant (limit - 2))]
        (All [Compare AtLeast (plus x (constant 1)) (constant (-limit)),
          Compare LessThan (plus x (constant 1)) (constant limit)]) `shouldBe` Proven
  it "handles sign reversal, disequality, and rational coefficients" $ do
    check [Compare GreaterThan x (constant (1 % 3))]
      (Compare LessThan (scale (-3) x) (constant (-1))) `shouldBe` Proven
    check [Compare NotEqualTo x zero]
      (Any [Compare LessThan x zero, Compare GreaterThan x zero]) `shouldBe` Proven
    check [Compare NotEqualTo x zero] (Compare GreaterThan x zero) `shouldBe` Unknown
  it "combines Boolean assumptions with arithmetic without inventing facts" $ do
    let flag = Atom (Id "flag")
        positive = Compare GreaterThan x zero
    check [Any [Not flag, positive], flag] positive `shouldBe` Proven
    check [Any [Not flag, positive]] positive `shouldBe` Unknown
    check [All [flag, positive]] (All [positive, flag]) `shouldBe` Proven
  it "treats contradictory domains vacuously without calling them inhabited" $ do
    check [Compare LessThan x zero, Compare AtLeast x zero] (Truth False) `shouldBe` Proven
    check [Truth False] (Atom (Id "anything")) `shouldBe` Proven
    check [] (Truth False) `shouldBe` Unknown
  it "returns unknown when work is exhausted" $ do
    prove 0 [] (Truth True) `shouldBe` Unknown
    let choices = All [Any [Atom (Id ("a" ++ show i)), Atom (Id ("b" ++ show i))] | i <- [1..20 :: Int]]
    prove 100 [choices] (Atom (Id "missing")) `shouldBe` Unknown
    prove 1 [Compare EqualTo x zero] (Compare EqualTo x zero) `shouldBe` Unknown
  it "does not assume rational variables are integers" $ do
    check [Compare AtLeast x zero, Compare LessThan x (constant 1)]
      (Compare EqualTo x zero) `shouldBe` Unknown
  it "tightens strict comparisons only with established integrality" $ do
    let upper = constant 127
        nextFits = Compare AtMost (plus x (constant 1)) upper
    check [IntegerCompare LessThan x upper] nextFits `shouldBe` Proven
    check [Compare LessThan x upper] nextFits `shouldBe` Unknown
    check [Not (IntegerCompare AtMost x upper)]
      (Compare AtLeast x (constant 128)) `shouldBe` Proven
    check [IntegerCompare NotEqualTo x upper, Compare AtMost x upper]
      (Compare AtMost x (constant 126)) `shouldBe` Proven
    check [IntegerCompare AtLeast x zero, IntegerCompare LessThan x (constant 1)]
      (Compare EqualTo x zero) `shouldBe` Proven
  it "checks integer implication normalization against exact finite assignments" $ do
    let relations = [EqualTo, NotEqualTo, LessThan, AtMost, GreaterThan, AtLeast]
        comparisons = [IntegerCompare r a b | r <- relations,
          (a,b) <- [(x,y),(plus x (constant 1),y),(x,zero)]]
        assumptions = [Not p | p <- comparisons] ++ comparisons
        assignments = [M.fromList [(Id "x",a),(Id "y",b)] | a <- [-3..3], b <- [-3..3]]
    forM_ [(a,b) | a <- assumptions, b <- comparisons, check [a] b == Proven] $ \(a,b) ->
      forM_ assignments $ \env ->
        case evaluatePredicate env M.empty a of
          Just False -> pure ()
          Just True -> evaluatePredicate env M.empty b `shouldBe` Just True
          Nothing -> expectationFailure "incomplete integer assignment"
  it "agrees with an independent exact enumeration on proved implications" $ do
    let expressions = [zero, x, y, plus x y, plus x (scale (-1) y), scale (-2) x, constant (1 % 2)]
        relations = [EqualTo, NotEqualTo, LessThan, AtMost, GreaterThan, AtLeast]
        comparisons = [Compare r a b | (a,b) <- zip expressions (reverse expressions), r <- relations]
        assumptions = [All [a,b] | (a,b) <- zip comparisons (drop 1 (cycle comparisons))]
        values = [-2, -1, -1 % 2, 0, 1 % 2, 1, 2]
        assignments = [M.fromList [(Id "x",a),(Id "y",b)] | a <- values, b <- values]
        -- Direct Rational evaluation does not use normalization or elimination.
        reference env (Truth b) = b
        reference env (All ps) = all (reference env) ps
        reference env (Compare r a b) = case (evaluateLinear env a,evaluateLinear env b) of
          (Just left, Just right) -> case r of
            EqualTo -> left == right
            NotEqualTo -> left /= right
            LessThan -> left < right
            AtMost -> left <= right
            GreaterThan -> left > right
            AtLeast -> left >= right
          _ -> error "incomplete independent assignment"
        reference _ _ = error "unsupported independent fixture"
    forM_ [(a,b) | a <- assumptions, b <- comparisons, check [a] b == Proven] $ \(a,b) ->
      forM_ assignments $ \env ->
        (not (reference env a) || reference env b) `shouldBe` True
