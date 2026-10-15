-- | Bounded candidate schedules use the existing typed strategy tree. Candidate
-- computations, filters and dependent binds become ordinary Core lets and
-- conditionals, evaluated by the same evaluator and native checked functions.
module LawSpec.Core.Search (Candidate(..), applyCandidate, strategyCandidates) where

import LawSpec.Core
import LawSpec.Scalar (Scalar(..))

data Candidate = Candidate Expr | CandidateGuard Expr Candidate
  | CandidateLet Binder Expr Candidate
  deriving (Eq, Show)

-- A rejected filter supplies the caller's inconclusive/neutral outcome. Each
-- visited computation is bound once, including a value used by a filter.
applyCandidate :: Candidate -> (Expr -> Expr) -> Expr -> Expr
applyCandidate candidate accepted rejected = case candidate of
  Candidate value -> accepted value
  CandidateGuard predicate inner -> Expr (expressionType rejected)
    (If predicate (applyCandidate inner accepted rejected) rejected) (expressionOrigin predicate)
  CandidateLet binder value inner -> let result = applyCandidate inner accepted rejected
    in Expr (expressionType result) (Let binder value result) (expressionOrigin value)

mapCandidate :: (Expr -> Candidate) -> Candidate -> Candidate
mapCandidate f candidate = case candidate of
  Candidate value -> f value
  CandidateGuard predicate inner -> CandidateGuard predicate (mapCandidate f inner)
  CandidateLet binder value inner -> CandidateLet binder value (mapCandidate f inner)

-- Strategies keep their lexical bindings and filters. A finite list supplied
-- by a strategy is a search choice, never a complete cover of the law's type.
-- Weighted cycles and diagonal dependent products are deterministic, so the
-- same plan is replayed on every target; outer framework seeds still control
-- the enclosing generated inputs.
strategyCandidates :: Int -> (Type -> Maybe Quantifier -> Either String [Expr])
  -> Draw -> Either String [Candidate]
strategyCandidates requested pool = go
  where
    budget = max 0 requested
    bounded = take budget
    go draw = case draw of
      DrawAny ty aim -> do
        values <- bounded <$> pool ty aim
        pure (map (maybe id filtered aim . Candidate) values)
      DrawOneOf _ values -> pure (map Candidate (bounded values))
      DrawFrequency alternatives -> do
        branches <- mapM (\(weight,inner) -> (,) weight <$> go inner) alternatives
        let available = [(weight,values) | (weight,values) <- branches,weight > 0,not (null values)]
            total = sum (map fst available)
            select _ [] = Nothing
            select slot ((weight,values):rest)
              | slot < weight = Just (weight,values,slot)
              | otherwise = select (slot-weight) rest
        pure [values !! fromInteger ((cycleIndex*weight + slot) `mod` toInteger (length values)) |
          index <- [0..toInteger budget-1],total > 0,
          let (cycleIndex,position) = index `divMod` total,
          Just (weight,values,slot) <- [select position available]]
      DrawSuchThat inner binder predicate discards -> do
        values <- go inner
        let limit = fromInteger (min (toInteger budget) (max 0 discards + 1))
        pure (map (filterWith binder predicate) (take limit values))
      DrawBind binder from body -> do
        first <- go from
        later <- go body
        pure (bounded [mapCandidate (\value -> CandidateLet binder value result) initial |
          diagonal <- [0..length first + length later - 2],
          i <- [max 0 (diagonal-length later+1)..min diagonal (length first-1)],
          let j = diagonal-i,initial <- [first !! i],result <- [later !! j]])
    filtered q = filterWith (quantifiedBinder q) (foldr conjunction truth (quantifiedPredicates q))
      where
        origin = GeneratedFrom (binderId (quantifiedBinder q))
        truth = Expr (scalarType "Bool") (Constant (SBool True)) origin
        conjunction a b = Expr (scalarType "Bool") (ShortCircuit And a b) origin
    filterWith binder predicate = mapCandidate (\value -> CandidateLet binder value
      (CandidateGuard predicate (Candidate (Expr (binderType binder) (Local (binderId binder)) (expressionOrigin value)))))
