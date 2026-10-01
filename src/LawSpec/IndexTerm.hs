-- The index structure of an indexed family, shared by elaboration, Core,
-- generation and runtime validation. An index of a value is computed from the
-- indices of its fields, so a family is a table: per constructor, one term per
-- index, and guards every value satisfies (a subtraction never underflows,
-- sibling fields share an index).
module LawSpec.IndexTerm
  ( IndexOperation(..), IndexTerm(..), IndexRelation(..), IndexGuard(..)
  , ConstructorIndex(..), FamilyIndex(..)
  , indexOperationName, evaluateIndex, guardHolds, termFields, subtractionGuards
  , indexTermText, indexGuardText, constructorIndexTexts
  ) where

import Data.List (nub)

data IndexOperation = IndexAdd | IndexSubtract | IndexMultiply | IndexQuotient | IndexRemainder | IndexPower
  deriving (Eq, Ord, Show, Enum, Bounded)

-- A field reference names a field position and the position of the index
-- within that field's own family.
data IndexTerm
  = IndexConstant Integer
  | IndexField Int Int
  | IndexApply IndexOperation IndexTerm IndexTerm
  deriving (Eq, Ord, Show)

data IndexRelation = IndexEqual | IndexAtLeast deriving (Eq, Ord, Show)

data IndexGuard = IndexGuard IndexRelation IndexTerm IndexTerm deriving (Eq, Ord, Show)

data ConstructorIndex = ConstructorIndex
  { constructorIndexTerms :: [IndexTerm]
  , constructorIndexGuards :: [IndexGuard]
  } deriving (Eq, Show)

-- Index names in declaration order; constructors are keyed by source name.
data FamilyIndex = FamilyIndex
  { familyIndexNames :: [String]
  , familyIndexConstructors :: [(String, ConstructorIndex)]
  } deriving (Eq, Show)

indexOperationName :: IndexOperation -> String
indexOperationName op = case op of
  IndexAdd -> "+"
  IndexSubtract -> "-"
  IndexMultiply -> "*"
  IndexQuotient -> "div"
  IndexRemainder -> "mod"
  IndexPower -> "^"

-- Natural semantics: subtraction below zero, division by zero and a negative
-- exponent have no value. Callers treat Nothing as "no such index".
evaluateIndex :: (Int -> Int -> Maybe Integer) -> IndexTerm -> Maybe Integer
evaluateIndex field term = case term of
  IndexConstant n -> Just n
  IndexField position index -> field position index
  IndexApply op a b -> do
    x <- evaluateIndex field a
    y <- evaluateIndex field b
    case op of
      IndexAdd -> Just (x + y)
      IndexSubtract | x >= y -> Just (x - y)
                    | otherwise -> Nothing
      IndexMultiply -> Just (x * y)
      IndexQuotient | y > 0 -> Just (x `div` y)
                    | otherwise -> Nothing
      IndexRemainder | y > 0 -> Just (x `mod` y)
                     | otherwise -> Nothing
      IndexPower | y >= 0 -> Just (x ^ y)
                 | otherwise -> Nothing

guardHolds :: (Int -> Int -> Maybe Integer) -> IndexGuard -> Bool
guardHolds field (IndexGuard relation a b) = case (evaluateIndex field a, evaluateIndex field b) of
  (Just x, Just y) -> case relation of
    IndexEqual -> x == y
    IndexAtLeast -> x >= y
  _ -> False

-- Runtimes receive terms and guards in prefix notation: c<n> is a literal,
-- f<i> the first index of field i (f<i>.<j> its index j), then operators.
indexTermText :: IndexTerm -> String
indexTermText term = case term of
  IndexConstant n -> "c" ++ show n
  IndexField position 0 -> "f" ++ show position
  IndexField position index -> "f" ++ show position ++ "." ++ show index
  IndexApply op a b -> unwords [indexOperationName op, indexTermText a, indexTermText b]

indexGuardText :: IndexGuard -> String
indexGuardText (IndexGuard relation a b) =
  unwords [case relation of IndexEqual -> "=="; IndexAtLeast -> ">=", indexTermText a, indexTermText b]

-- One term per index, then the guards (which start with == or >=).
constructorIndexTexts :: ConstructorIndex -> [String]
constructorIndexTexts (ConstructorIndex terms guards) = map indexTermText terms ++ map indexGuardText guards

termFields :: IndexTerm -> [(Int, Int)]
termFields term = nub $ case term of
  IndexConstant _ -> []
  IndexField position index -> [(position, index)]
  IndexApply _ a b -> termFields a ++ termFields b

-- Each subtraction requires its left operand to be at least its right one,
-- so an index never truncates at zero.
subtractionGuards :: IndexTerm -> [IndexGuard]
subtractionGuards term = case term of
  IndexApply IndexSubtract a b -> IndexGuard IndexAtLeast a b : subtractionGuards a ++ subtractionGuards b
  IndexApply op a b | op `elem` [IndexQuotient, IndexRemainder] ->
    IndexGuard IndexAtLeast b (IndexConstant 1) : subtractionGuards a ++ subtractionGuards b
  IndexApply _ a b -> subtractionGuards a ++ subtractionGuards b
  _ -> []
