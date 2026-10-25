-- | Complete finite covers inferred from mandatory conjuncts of a logical
-- restriction. Other predicates remain in the checked search term. A cover
-- is never inferred from disjunction, floating-point order or sampled values.
module LawSpec.Core.QuantifierDomain (finiteQuantifierTerms, finiteQuantifierCandidates) where

import LawSpec.Core
import LawSpec.Core.Value
import LawSpec.Core.Search (Candidate(..))
import LawSpec.Scalar (Scalar(..), isInteger, integerBounds)
import qualified Data.Map.Strict as M
import Data.List (minimumBy)
import Data.Ord (comparing)

type Linear = (M.Map Id Integer, Integer)

finiteQuantifierTerms :: Int -> Int -> (Type -> Either String (Maybe [Value]))
  -> Quantifier -> Either String (Maybe [Expr])
finiteQuantifierTerms bits limit domain q = fmap (fmap fst) (finiteDomain bits limit domain q)

-- Execution keeps the intrinsic range guard outside the checked conversion.
-- An out-of-range affine point is skipped, rather than becoming another visit
-- to a clipped endpoint. The term view remains useful for pure proof goals.
finiteQuantifierCandidates :: Int -> Int -> (Type -> Either String (Maybe [Value]))
  -> Quantifier -> Either String (Maybe [Candidate])
finiteQuantifierCandidates bits limit domain q = fmap (fmap snd) (finiteDomain bits limit domain q)

finiteDomain :: Int -> Int -> (Type -> Either String (Maybe [Value]))
  -> Quantifier -> Either String (Maybe ([Expr], [Candidate]))
finiteDomain bits limit domain q = do
  available <- domain ty
  case integerCover of
    Just terms -> pure (Just terms)
    Nothing -> traverse (fmap (\terms -> (terms,map Candidate terms)) . mapM valueTerm) available
  where
    binder = quantifiedBinder q
    current = binderId binder
    ty = binderType binder
    origin = GeneratedFrom current
    integerCover = case ty of
      Constructor name [] | isInteger name -> do
        let intrinsic = case integerBounds bits name of
              Just (lo,hi) -> [(GreaterEqual,(M.empty,lo)),(LessEqual,(M.empty,hi))]
              Nothing | name == "BigUInt" -> [(GreaterEqual,(M.empty,0))]
              _ -> []
            bounds = intrinsic ++ concatMap constraints (quantifiedPredicates q)
            lowers = [n | (GreaterEqual,(a,n)) <- bounds,M.null a]
            uppers = [n | (LessEqual,(a,n)) <- bounds,M.null a]
            constants = [((M.empty,maximum lowers),(M.empty,minimum uppers)) |
              not (null lowers),not (null uppers)]
            intervals = constants ++ [(lo,hi) | (GreaterEqual,lo@(a,_)) <- bounds,
              (LessEqual,hi@(b,_)) <- bounds,a == b,not (M.null a)]
        ((variables,lower),(_,upper)) <- case intervals of
          [] -> Nothing
          _ -> Just (minimumBy (comparing (\((_,a),(_,b)) -> b-a)) intervals)
        if upper < lower then Just ([],[])
        else if upper-lower+1 > toInteger limit then Nothing
        else Just ([term name (variables,n) | n <- [lower..upper]],
                   [candidate name (variables,n) | n <- [lower..upper]])
      _ -> Nothing
    constraints expression = case expressionNode expression of
      ShortCircuit And a b -> constraints a ++ constraints b
      Binary op (Numeric _) a b | op `elem` [Equal,Less,LessEqual,Greater,GreaterEqual] ->
        case difference <$> linear a <*> linear b of
          Just (variables,offset) -> case M.lookup current variables of
            Just coefficient | coefficient `elem` [1,-1] ->
              let rest = M.delete current variables
                  right = (M.map (* negate coefficient) rest,negate coefficient * offset)
                  operation = if coefficient == 1 then op else reverseOrder op
              in normalBounds operation right
            _ -> []
          Nothing -> []
      _ -> []
    normalBounds Equal value = [(GreaterEqual,value),(LessEqual,value)]
    normalBounds Greater value = [(GreaterEqual,shift 1 value)]
    normalBounds Less value = [(LessEqual,shift (-1) value)]
    normalBounds op value = [(op,value)]
    reverseOrder Less = Greater
    reverseOrder LessEqual = GreaterEqual
    reverseOrder Greater = Less
    reverseOrder GreaterEqual = LessEqual
    reverseOrder op = op
    shift n (variables,offset) = (variables,offset+n)
    difference (a,x) (b,y) = (M.filter (/=0) (M.unionWith (+) a (M.map negate b)),x-y)
    plus a b = difference a (scale (-1) b)
    scale n (variables,offset) = (M.filter (/=0) (M.map (*n) variables),n*offset)
    linear :: Expr -> Maybe Linear
    linear expression = case expressionType expression of
      Constructor name [] | isInteger name -> case expressionNode expression of
        Constant (SInteger _ n) -> Just (M.empty,n)
        Local identity -> Just (M.singleton identity 1,0)
        Unary Negate value -> scale (-1) <$> linear value
        Binary Add (Numeric _) a b -> plus <$> linear a <*> linear b
        Binary Subtract (Numeric _) a b -> difference <$> linear a <*> linear b
        Binary Multiply (Numeric _) a b -> do
          left@(xs,x) <- linear a
          right@(ys,y) <- linear b
          if M.null xs then Just (scale x right)
          else if M.null ys then Just (scale y left) else Nothing
        Convert _ (Constructor target []) value | target `elem` ["Integer","BigInt"] -> linear value
        _ -> Nothing
      _ -> Nothing
    -- Symbolic candidates are computed in exact signed integers, then clipped
    -- before a checked conversion to their intrinsic domain. Every admitted
    -- value of the affine interval is unchanged by clipping. Extra endpoint
    -- copies remain subject to the original restriction and establish no new
    -- witness. This also handles an interval wholly outside a bounded type.
    locals = M.fromList [(identity,expressionType expression) |
      predicate <- quantifiedPredicates q,expression <- descend predicate,
      Local identity <- [expressionNode expression]]
    descend expression = expression : concatMap descend (children expression)
    candidate name affine@(variables,_)
      | M.null variables = Candidate (term name affine)
      | otherwise = let
          integer = scalarType "Integer"
          value = exactTerm affine
          constant n = Expr integer (Constant (SInteger "Integer" n)) origin
          compare op n = Expr (scalarType "Bool") (Binary op (Numeric integer) value (constant n)) origin
          converted = Expr ty (Convert CheckedArgument ty value) origin
          within = case integerBounds bits name of
            Just (lo,hi) -> Just (Expr (scalarType "Bool")
              (ShortCircuit And (compare GreaterEqual lo) (compare LessEqual hi)) origin)
            Nothing | name == "BigUInt" -> Just (compare GreaterEqual 0)
            _ -> Nothing
          in maybe id CandidateGuard within (Candidate converted)
    exactTerm (variables,offset) = let
      integer = scalarType "Integer"
      constant n = Expr integer (Constant (SInteger "Integer" n)) origin
      operation op a b = Expr integer (Binary op (Numeric integer) a b) origin
      local identity = let
        t = M.findWithDefault integer identity locals
        e = Expr t (Local identity) origin
        in if t == integer then e else Expr integer (Convert CheckedArgument integer e) origin
      part (identity,coefficient) = if coefficient == 1 then local identity
        else operation Multiply (constant coefficient) (local identity)
      in foldl (operation Add) (constant offset) (map part (M.toAscList variables))
    term name (variables,offset)
      | M.null variables = Expr ty (Constant (SInteger name offset)) origin
      | otherwise = let
          integer = scalarType "Integer"
          constant n = Expr integer (Constant (SInteger "Integer" n)) origin
          value = exactTerm (variables,offset)
          lowerBound lo expression = Expr integer (If
            (Expr (scalarType "Bool") (Binary Less (Numeric integer) expression (constant lo)) origin)
            (constant lo) expression) origin
          upperBound hi expression = Expr integer (If
            (Expr (scalarType "Bool") (Binary Greater (Numeric integer) expression (constant hi)) origin)
            (constant hi) expression) origin
          clipped = case integerBounds bits name of
            Just (lo,hi) -> upperBound hi (lowerBound lo value)
            Nothing | name == "BigUInt" -> lowerBound 0 value
            _ -> value
          in if ty == integer then value else Expr ty (Convert CheckedArgument ty clipped) origin
    valueTerm value = case value of
      ScalarValue scalar -> pure (Expr (valueType value) (Constant scalar) origin)
      DataValue t tag values -> (\terms -> Expr t (Construct tag terms) origin) <$> mapM valueTerm values
      PresenceValue t _ -> (\scalar -> Expr t (Constant scalar) origin) <$> toScalarValue value
