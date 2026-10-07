-- | Constant integer bounds from refinements, so generators draw from the
-- range a refinement allows instead of filtering a whole type's range.
module LawSpec.Bounds (bounds, inputRange) where

import qualified LawSpec.Core as C
import LawSpec.Scalar (Scalar(..), integerBounds, isInteger)

-- | The tightest constant bounds a precondition conjunction puts on a binder.
bounds :: C.Id -> [C.Expr] -> (Maybe Integer, Maybe Integer)
bounds binder = foldl tighten (Nothing, Nothing) . concatMap conjuncts
  where
    conjuncts e = case C.expressionNode e of
      C.ShortCircuit C.And a b -> conjuncts a ++ conjuncts b
      _ -> [e]
    tighten (lo, hi) e = case C.expressionNode e of
      C.Binary op _ a b -> case (local a, constant b, constant a, local b) of
        (True, Just n, _, _) -> apply op n (lo, hi)
        (_, _, Just n, True) -> apply (flipped op) n (lo, hi)
        _ -> (lo, hi)
      _ -> (lo, hi)
    local e = case C.expressionNode e of
      C.Local i -> i == binder
      C.Convert _ _ inner -> local inner
      _ -> False
    constant e = case C.expressionNode e of
      C.Constant (SInteger _ n) -> Just n
      C.Convert _ _ inner -> constant inner
      _ -> Nothing
    apply op n (lo, hi) = case op of
      C.GreaterEqual -> (Just (maybe n (max n) lo), hi)
      C.Greater -> (Just (maybe (n + 1) (max (n + 1)) lo), hi)
      C.LessEqual -> (lo, Just (maybe n (min n) hi))
      C.Less -> (lo, Just (maybe (n - 1) (min (n - 1)) hi))
      C.Equal -> (Just n, Just n)
      _ -> (lo, hi)
    flipped op = case op of
      C.GreaterEqual -> C.LessEqual
      C.Greater -> C.Less
      C.LessEqual -> C.GreaterEqual
      C.Less -> C.Greater
      other -> other


-- | An integer input's range: its type's bounds narrowed by the constant
-- bounds its refinements put on it. Nothing for other inputs, or when the
-- refinements set no bound.
inputRange :: Int -> C.Quantifier -> Maybe (Integer, Integer)
inputRange bits q = case C.binderType (C.quantifiedBinder q) of
  C.Constructor n [] | isInteger n, (lo, hi) <- bounds (C.binderId (C.quantifiedBinder q)) (C.quantifiedPredicates q)
                     , lo /= Nothing || hi /= Nothing ->
    let typed = integerBounds bits n
        low = maximum (concat [[l | Just l <- [lo]], [fst t | Just t <- [typed]], [-2 ^ (256 :: Int) | lo == Nothing && typed == Nothing && n /= "BigUInt"], [0 | n `elem` ["BigUInt", "Natural"], lo == Nothing]])
        high = minimum (concat [[h | Just h <- [hi]], [snd t | Just t <- [typed]], [2 ^ (256 :: Int) | hi == Nothing && typed == Nothing]])
    -- Native generators draw 64-bit integers; a wider range filters.
    in if low <= high && low >= -(2 ^ (63 :: Int)) && high <= 2 ^ (64 :: Int) - 1 && (low >= 0 || high < 2 ^ (63 :: Int))
         then Just (low, high) else Nothing
  _ -> Nothing
