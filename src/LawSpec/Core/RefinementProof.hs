-- | Exact linear implication checking for refinement obligations. Variables range
-- over rationals: this is sound (but deliberately incomplete) for integer inputs
-- too. Floating expressions must never be lowered to this proof language.
module LawSpec.Core.RefinementProof
  ( Linear, constant, variable, plus, scale, evaluateLinear
  , Relation(..), Predicate(..), Verdict(..), prove, evaluatePredicate
  ) where

import qualified Data.Map.Strict as M
import Data.List (nub, minimumBy)
import Data.Ord (comparing)
import Control.Monad.State.Strict
import Control.Monad (foldM)
import LawSpec.Core (Id)

-- | Obligations are kept linear, a constant plus rational multiples of
-- variables, because linear implication over the rationals is decidable and
-- cheap, and that covers the index and bound arithmetic laws use.
-- ref:DEC-proof-producing-index-layer
data Linear = Linear Rational (M.Map Id Rational) deriving (Eq, Ord, Show)

-- | A term with no variables.
constant :: Rational -> Linear
constant n = Linear n M.empty

-- | A term that is one variable with coefficient one.
variable :: Id -> Linear
variable name = Linear 0 (M.singleton name 1)

-- | Zero coefficients are dropped, so equal terms have one representation.
plus :: Linear -> Linear -> Linear
plus (Linear a xs) (Linear b ys) =
  Linear (a + b) (M.filter (/= 0) (M.unionWith (+) xs ys))

-- | As plus, scaling keeps the representation normal.
scale :: Rational -> Linear -> Linear
scale n (Linear a xs) = Linear (n * a) (M.filter (/= 0) (M.map (n *) xs))

-- | A counterexample search evaluates terms at concrete values; a missing value
-- means the term cannot be judged there.
evaluateLinear :: M.Map Id Rational -> Linear -> Maybe Rational
evaluateLinear values (Linear n xs) =
  (n +) . sum <$> mapM (\(name,k) -> (k *) <$> M.lookup name values) (M.toList xs)

-- | The six comparisons a refinement may state between linear terms.
data Relation = EqualTo | NotEqualTo | LessThan | AtMost | GreaterThan | AtLeast
  deriving (Eq, Ord, Show)

-- | Refinements are lowered into this small language, so the prover never sees
-- floating arithmetic, which has no exact identities. ref:ieee-754
data Predicate
  = Truth Bool
  | Atom Id
  | Compare Relation Linear Linear
  -- Typed lowering must establish that both values are integral.
  | IntegerCompare Relation Linear Linear
  | Not Predicate
  | All [Predicate]
  | Any [Predicate]
  deriving (Eq, Ord, Show)

-- | Unknown is not a counterexample: it includes exhausted proof work budgets.
data Verdict = Proven | Unknown deriving (Eq, Show)

-- | A candidate counterexample is checked against the predicate exactly.
evaluatePredicate :: M.Map Id Rational -> M.Map Id Bool -> Predicate -> Maybe Bool
evaluatePredicate numbers booleans predicate = case predicate of
  Truth b -> Just b
  Atom name -> M.lookup name booleans
  Compare relation a b -> relationFunction relation <$> evaluateLinear numbers a <*> evaluateLinear numbers b
  IntegerCompare relation a b -> relationFunction relation <$> evaluateLinear numbers a <*> evaluateLinear numbers b
  Not p -> not <$> evaluatePredicate numbers booleans p
  All ps -> conjunction ps
  Any ps -> disjunction ps
  where
    recur = evaluatePredicate numbers booleans
    conjunction [] = Just True
    conjunction (p:ps) = do b <- recur p; if b then conjunction ps else Just False
    disjunction [] = Just False
    disjunction (p:ps) = do b <- recur p; if b then Just True else disjunction ps

relationFunction :: Ord a => Relation -> a -> a -> Bool
relationFunction relation = case relation of
  EqualTo -> (==)
  NotEqualTo -> (/=)
  LessThan -> (<)
  AtMost -> (<=)
  GreaterThan -> (>)
  AtLeast -> (>=)

-- | An inequality represents linear <= 0, or linear < 0 when strict is True.
data Inequality = Inequality Linear Bool deriving (Eq, Ord, Show)
data Conjunct = Numeric Inequality | Boolean Id Bool deriving (Eq, Ord, Show)
type Work = StateT Int Maybe

spend :: Int -> Work ()
spend n = do
  available <- get
  if n > available then lift Nothing else put (available - n)

-- | The search is bounded by a budget, so compilation always terminates; running
-- out of budget gives Unknown, which is safe. ref:DEC-evidence-statuses
prove :: Int -> [Predicate] -> Predicate -> Verdict
prove budget assumptions conclusion
  | budget <= 0 = Unknown
  | otherwise = case evalStateT obligation budget of
      Just True -> Proven
      _ -> Unknown
  where
    obligation = do
      alternatives <- normalForm True (All (assumptions ++ [Not conclusion]))
      and <$> mapM inconsistent alternatives

-- | Bounded disjunctive normalization keeps Boolean reasoning explicit. Every
-- resulting branch must be inconsistent to prove the original implication.
normalForm :: Bool -> Predicate -> Work [[Conjunct]]
normalForm truth predicate = do
  spend 1
  case predicate of
    Truth b -> pure (if b == truth then [[]] else [])
    Atom name -> pure [[Boolean name truth]]
    Not p -> normalForm (not truth) p
    All ps | truth -> conjunction ps
           | otherwise -> disjunction ps
    Any ps | truth -> disjunction ps
           | otherwise -> conjunction ps
    Compare relation a b -> comparison (if truth then relation else complement relation) (plus a (scale (-1) b))
    IntegerCompare relation a b ->
      let value = plus a (scale (-1) b)
      in case if truth then relation else complement relation of
        LessThan -> comparison AtMost (plus value (constant 1))
        GreaterThan -> comparison AtLeast (plus value (constant (-1)))
        NotEqualTo -> do
          lower <- comparison AtMost (plus value (constant 1))
          upper <- comparison AtLeast (plus value (constant (-1)))
          pure (lower ++ upper)
        other -> comparison other value
  where
    disjunction ps = do
      parts <- mapM (normalForm truth) ps
      spend (sum (map length parts))
      pure (concat parts)
    conjunction ps = foldM combine [[]] ps
    combine branches p = do
      next <- normalForm truth p
      -- Check multiplication without overflowing the bounded Int work counter.
      remaining <- get
      if toInteger (length branches) * toInteger (length next) > toInteger remaining
        then lift Nothing
        else do
          spend (length branches * length next)
          pure [a ++ b | a <- branches, b <- next]
    comparison relation value = pure $ case relation of
      EqualTo -> [[bound False value, bound False (scale (-1) value)]]
      NotEqualTo -> [[bound True value], [bound True (scale (-1) value)]]
      LessThan -> [[bound True value]]
      AtMost -> [[bound False value]]
      GreaterThan -> [[bound True (scale (-1) value)]]
      AtLeast -> [[bound False (scale (-1) value)]]
    bound strict value = Numeric (Inequality value strict)

complement :: Relation -> Relation
complement relation = case relation of
  EqualTo -> NotEqualTo
  NotEqualTo -> EqualTo
  LessThan -> AtLeast
  AtMost -> GreaterThan
  GreaterThan -> AtMost
  AtLeast -> LessThan

inconsistent :: [Conjunct] -> Work Bool
inconsistent conjuncts = do
  spend (length conjuncts)
  let booleans = [(name,b) | Boolean name b <- conjuncts]
  if any (\(name,b) -> (name,not b) `elem` booleans) booleans
    then pure True
    else eliminate (nub [inequality | Numeric inequality <- conjuncts])

-- | Fourier-Motzkin elimination combines each lower bound with each upper bound.
-- Positive scaling preserves order. A combined bound is strict if either input
-- is strict; dropping that distinction would mishandle boundary equalities.
eliminate :: [Inequality] -> Work Bool
eliminate inequalities = do
  spend (length inequalities + 1)
  if any contradiction inequalities then pure True
  else case nub (concat [M.keys coefficients | Inequality (Linear _ coefficients) _ <- inequalities]) of
    [] -> pure False
    variables -> do
      let coefficient name (Inequality (Linear _ coefficients) _) = M.findWithDefault 0 name coefficients
          cost name = toInteger (length (filter ((> 0) . coefficient name) inequalities)) *
            toInteger (length (filter ((< 0) . coefficient name) inequalities))
          name = minimumBy (comparing cost) variables
          positive = filter ((> 0) . coefficient name) inequalities
          negative = filter ((< 0) . coefficient name) inequalities
          independent = filter ((== 0) . coefficient name) inequalities
      remaining <- get
      if cost name > toInteger remaining then lift Nothing
      else do
        spend (fromInteger (cost name))
        let combine upper@(Inequality a strictA) lower@(Inequality b strictB) =
              Inequality (plus (scale (negate (coefficient name lower)) a)
                (scale (coefficient name upper) b)) (strictA || strictB)
        eliminate (nub (independent ++ [combine upper lower | upper <- positive, lower <- negative]))
  where
    contradiction (Inequality (Linear n coefficients) strict) =
      M.null coefficients && if strict then n >= 0 else n > 0
