-- | Complete finite covers inferred from mandatory conjuncts of a logical
-- restriction. Other predicates remain in the checked search term. A cover
-- is never inferred from disjunction, floating-point order or sampled values.
module LawSpec.Core.QuantifierDomain (finiteQuantifierTerms) where

import LawSpec.Core
import LawSpec.Core.Value
import LawSpec.Scalar (Scalar(..), isInteger, integerBounds)
import qualified Data.Map.Strict as M
import Data.List (minimumBy)
import Data.Ord (comparing)

type Linear = (M.Map Id Integer, Integer)

finiteQuantifierTerms :: Int -> Int -> (Type -> Either String (Maybe [Value]))
  -> Quantifier -> Either String (Maybe [Expr])
finiteQuantifierTerms bits limit domain q = do
  available <- domain ty
  case integerCover of
    Just terms -> pure (Just terms)
    Nothing -> traverse (mapM valueTerm) available
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
              (LessEqual,hi@(b,_)) <- bounds,a == b,not (M.null a),
              name `elem` ["Integer","BigInt"]]
        ((variables,lower),(_,upper)) <- case intervals of
          [] -> Nothing
          _ -> Just (minimumBy (comparing (\((_,a),(_,b)) -> b-a)) intervals)
        if upper < lower then Just []
        else if upper-lower+1 > toInteger limit then Nothing
        else Just [term name (variables,n) | n <- [lower..upper]]
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
    -- Symbolic covers are built in exact signed integers. Finite-width and
    -- unsigned covers use constants inside their intrinsic range instead.
    locals = M.fromList [(identity,expressionType expression) |
      predicate <- quantifiedPredicates q,expression <- descend predicate,
      Local identity <- [expressionNode expression]]
    descend expression = expression : concatMap descend (children expression)
    term name (variables,offset)
      | M.null variables = Expr ty (Constant (SInteger name offset)) origin
      | otherwise = let
          integer = scalarType "Integer"
          constant n = Expr integer (Constant (SInteger "Integer" n)) origin
          operation op a b = Expr integer (Binary op (Numeric integer) a b) origin
          local identity =
            let t = M.findWithDefault integer identity locals
                e = Expr t (Local identity) origin
            in if t == integer then e else Expr integer (Convert CheckedArgument integer e) origin
          part (identity,coefficient) = if coefficient == 1 then local identity
            else operation Multiply (constant coefficient) (local identity)
          value = foldl (operation Add) (constant offset) (map part (M.toAscList variables))
          in if ty == integer then value else Expr ty (Convert CheckedArgument ty value) origin
    valueTerm value = case value of
      ScalarValue scalar -> pure (Expr (valueType value) (Constant scalar) origin)
      DataValue t tag values -> (\terms -> Expr t (Construct tag terms) origin) <$> mapM valueTerm values
      PresenceValue t _ -> (\scalar -> Expr t (Constant scalar) origin) <$> toScalarValue value
