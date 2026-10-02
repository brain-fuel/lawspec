-- Structural values in the reference interpreter. Scalar encodings remain
-- lossless leaves; algebraic constructors never share absence representations.
module LawSpec.Core.Value
  ( Value(..), fromScalarValue, toScalarValue, validateValue, validateValueWith, ValueCheck(..), checkValueWith
  , equalValues, compareValues, listValue, listItems, valueIndex, valueType, witnessFields, witnessKey, witnessKeys
  ) where

import Control.Monad (unless, zipWithM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import LawSpec.Core (Type(..), Argument(..), Id(..), Expr, DataDeclaration(..), DataConstructor(..), binderId, binderType)
import qualified Data.Map.Strict as M
import LawSpec.Core.Types (TypeRegistry, checkType, constructorFieldsAt, constructorPredicatesFor, lookupData, freeExistentials, matchType, substitute)
import LawSpec.IndexTerm (FamilyIndex(..), ConstructorIndex(..), evaluateIndex, guardHolds)
import LawSpec.Core.Semantics (binaryValue)
import LawSpec.Scalar

data Value
  = ScalarValue Scalar
  | DataValue Type Id [Value]
  | PresenceValue Type (Maybe Value)
  deriving (Eq, Ord, Show)

fromScalarValue :: Type -> Scalar -> Value
fromScalarValue ty@(Constructor name [TypeArgument element]) (SPresent tag payload)
  | name == tag && name `elem` ["Nullable", "Optional"] =
      PresenceValue ty (fromScalarValue element <$> payload)
fromScalarValue _ scalar = ScalarValue scalar

toScalarValue :: Value -> Either String Scalar
toScalarValue (ScalarValue scalar) = Right scalar
toScalarValue (PresenceValue (Constructor name [TypeArgument _]) payload)
  | name `elem` ["Nullable", "Optional"] = SPresent name <$> traverse toScalarValue payload
toScalarValue _ = Left "structural value cannot cross a scalar-only adapter bridge"

validateValue :: TypeRegistry -> Int -> Type -> Value -> Either String Value
validateValue = validateValueWith (\_ _ -> Left "constructor field validation requires a predicate evaluator")

-- The callback avoids a Value/Eval module cycle. Recursive shape validation and
-- ordered predicate execution remain one operation; callers cannot accidentally
-- validate only the outer constructor and forget a constrained nested payload.
validateValueWith :: ([(Id,Value)] -> Expr -> Either String Value)
  -> TypeRegistry -> Int -> Type -> Value -> Either String Value
validateValueWith evaluate registry bits expected value = do
  result <- checkValueWith evaluate registry bits expected value
  case result of
    ValueAccepted checked -> pure checked
    RefinementRejected message -> Left message

-- Candidate generation must distinguish a false predicate from a malformed
-- value or an evaluation error. Rejection is data, not an exception to swallow.
data ValueCheck = ValueAccepted Value | RefinementRejected String deriving (Eq, Show)

checkValueWith :: ([(Id,Value)] -> Expr -> Either String Value)
  -> TypeRegistry -> Int -> Type -> Value -> Either String ValueCheck
checkValueWith evaluate registry bits expected value =
  either RefinementRejected ValueAccepted <$> runExceptT (walk expected value)
  where
    walk :: Type -> Value -> ExceptT String (Either String) Value
    walk expected value = do
      lift (checkType registry expected)
      case value of
        ScalarValue scalar -> case fromScalarValue expected scalar of
          normalized@(PresenceValue _ _) -> walk expected normalized
          _ -> case expected of
            Constructor name [] | name == scalarName scalar ->
              ScalarValue <$> lift (validateScalar bits scalar)
            _ -> lift (Left "scalar value does not match its declared type")
        PresenceValue actual payload -> case actual of
          Constructor name [TypeArgument element] | expected == actual && name `elem` ["Nullable", "Optional"] ->
            PresenceValue actual <$> traverse (walk element) payload
          _ -> lift (Left "presence value does not match its declared type")
        DataValue actual tag payload -> do
          lift $ unless (actual == expected) (Left "data value does not match its declared type")
          fields <- lift (constructorFieldsAt registry actual tag (map valueType payload))
          lift $ unless (length fields == length payload)
            (Left ("constructor payload arity mismatch: " ++ idText tag))
          checked <- zipWithM walk (map binderType fields) payload
          predicates <- lift (constructorPredicatesFor registry actual tag)
          let scope = zip (map binderId fields) checked
          mapM_ (\predicate -> do
            result <- lift $ either (Left . ((idText tag ++ ": field refinement: ") ++)) Right
              (evaluate scope predicate)
            case result of
              ScalarValue (SBool True) -> pure ()
              ScalarValue (SBool False) -> throwE (idText tag ++ ": field refinement failed")
              _ -> lift (Left (idText tag ++ ": field refinement did not produce Bool"))) predicates
          let field position index = case drop position checked of
                child : _ -> valueIndex registry child index
                [] -> Nothing
          unless (all (guardHolds field) (indexGuards actual tag))
            (throwE (idText tag ++ ": index guard failed"))
          canonicalCollection actual checked
          pure (DataValue actual tag checked)
    -- A Set's items and a KeyVal's keys strictly increase.
    canonicalCollection actual checked = case (actual, checked) of
      (Constructor name _, [items])
        | name `elem` [collections ++ "Set", collections ++ "KeyVal"] -> do
            values <- lift (listItems items)
            let key v = if name == collections ++ "KeyVal"
                  then case v of DataValue _ _ (k : _) -> k; _ -> v
                  else v
            orders <- lift (sequence [compareValues (key a) (key b) | (a, b) <- zip values (drop 1 values)])
            unless (all (== LT) orders)
              (throwE (name ++ ": items must be sorted and distinct"))
      _ -> pure ()
    collections = "lawspec.collections::type::"
    indexGuards actual tag = case actual of
      Constructor name _ | Right declaration <- lookupData registry (Id name)
                         , Just family <- dataIndex declaration
                         , Just (ConstructorIndex _ guards) <- lookup (idText tag) (familyIndexConstructors family) -> guards
      _ -> []

-- Runtimes carry a field-only existential's type as a trailing Text field,
-- after the declared ones: a witness, keyed by witnessKey.
witnessFields :: [DataDeclaration] -> Type -> Id -> [Value] -> [Value]
witnessFields declarations ty tag fields =
  map (ScalarValue . textScalar) (witnessKeys declarations ty tag (map valueType fields))

-- The witness keys of a construction from its declared fields' types; none
-- when the constructor has no field-only existential.
witnessKeys :: [DataDeclaration] -> Type -> Id -> [Type] -> [String]
witnessKeys declarations ty tag types = case ty of
  Constructor name arguments
    | declaration : _ <- [d | d <- declarations, dataId d == Id name]
    , constructor : _ <- [c | c <- dataConstructors declaration, constructorId c == tag]
    , free@(_ : _) <- freeExistentials declaration constructor ->
        let known = M.fromList (zip (dataParameters declaration) [t | TypeArgument t <- arguments])
            bound = foldl (\acc (field, actual) -> maybe acc id (matchType free acc (substitute known (binderType field)) actual))
              known (zip (constructorFields constructor) types)
        in [maybe "" witnessKey (M.lookup e bound) | e <- free]
  _ -> []

-- A witness spells a type as its name, or a parenthesized application.
witnessKey :: Type -> String
witnessKey ty = case ty of
  Constructor name [] -> name
  Constructor name arguments -> "(" ++ unwords (name : [witnessKey t | TypeArgument t <- arguments]) ++ ")"
  _ -> ""

-- The type a value carries: a field-only existential takes it from here.
valueType :: Value -> Type
valueType value = case value of
  ScalarValue scalar -> Constructor (scalarName scalar) []
  DataValue ty _ _ -> ty
  PresenceValue ty _ -> ty

-- An indexed family's index of a value, recomputed from its constructor's
-- term; Nothing when the value is not of an indexed family or has no value.
valueIndex :: TypeRegistry -> Value -> Int -> Maybe Integer
valueIndex registry value index = case value of
  DataValue (Constructor name _) tag fields -> do
    declaration <- either (const Nothing) Just (lookupData registry (Id name))
    family <- dataIndex declaration
    ConstructorIndex terms _ <- lookup (idText tag) (familyIndexConstructors family)
    term <- case drop index terms of
      t : _ -> Just t
      [] -> Nothing
    evaluateIndex (\position child -> case drop position fields of
      v : _ -> valueIndex registry v child
      [] -> Nothing) term
  _ -> Nothing

-- Do not use derived Eq for language equality: float NaNs and Symbol identity
-- retain their scalar semantics inside any number of constructors or wrappers.
equalValues :: Int -> Value -> Value -> Either String Bool
equalValues bits (ScalarValue a) (ScalarValue b) = do
  result <- binaryValue bits "==" a b
  case result of SBool answer -> Right answer; _ -> Left "equality did not produce Bool"
equalValues bits (DataValue ta ca as) (DataValue tb cb bs)
  | ta == tb && ca == cb && length as == length bs = equalFields as bs
  | otherwise = Right False
  where
    equalFields [] [] = Right True
    equalFields (x:xs) (y:ys) = do
      same <- equalValues bits x y
      if same then equalFields xs ys else Right False
    equalFields _ _ = Right False
equalValues bits (PresenceValue ta a) (PresenceValue tb b)
  | ta /= tb = Right False
  | otherwise = case (a,b) of
      (Nothing, Nothing) -> Right True
      (Just x, Just y) -> equalValues bits x y
      _ -> Right False
equalValues _ _ _ = Right False

-- The portable total order of keyed values, which every runtime implements
-- identically: exact numbers by value, sequences by their units, False before
-- True, and absence before presence. Lists compare element by element (a
-- prefix first), Nothing comes before Just, and other data compare by
-- constructor identity and then by fields left to right. Floats, complex
-- numbers and symbols have no portable order.
compareValues :: Value -> Value -> Either String Ordering
compareValues a b = case (a, b) of
  (ScalarValue x, ScalarValue y) -> scalar x y
  (PresenceValue _ x, PresenceValue _ y) -> optional (maybe [] pure x) (maybe [] pure y)
  (DataValue (Constructor "List" _) _ _, DataValue (Constructor "List" _) _ _) -> do
    xs <- listItems a
    ys <- listItems b
    sequenceOrder xs ys
  (DataValue (Constructor "Maybe" _) ca xs, DataValue (Constructor "Maybe" _) cb ys) ->
    optional (if idText ca == "Maybe::Just" then take 1 xs else []) (if idText cb == "Maybe::Just" then take 1 ys else [])
  (DataValue _ ca xs, DataValue _ cb ys)
    | ca == cb -> sequenceOrder xs ys
    | otherwise -> Right (compare (idText ca) (idText cb))
  _ -> Left "values of different shapes have no order"
  where
    optional x y = case (x, y) of
      ([], []) -> Right EQ
      ([], _) -> Right LT
      (_, []) -> Right GT
      (p : _, q : _) -> compareValues p q
    sequenceOrder [] [] = Right EQ
    sequenceOrder [] _ = Right LT
    sequenceOrder _ [] = Right GT
    sequenceOrder (x : xs) (y : ys) = do
      order <- compareValues x y
      if order == EQ then sequenceOrder xs ys else Right order
    scalar x y = case (x, y) of
      (SInteger _ m, SInteger _ n) -> Right (compare m n)
      (SDecimal c e, SDecimal d f) -> Right (compare (decimal c e) (decimal d f))
      (SRational n d, SRational m e) -> Right (compare (toRational n / toRational d) (toRational m / toRational e))
      (SBool p, SBool q) -> Right (compare p q)
      (SSequence _ ps, SSequence _ qs) -> Right (compare ps qs)
      (SCharacter _ p, SCharacter _ q) -> Right (compare p q)
      (SAbsent _, SAbsent _) -> Right EQ
      (SPresent _ p, SPresent _ q) -> case (p, q) of
        (Nothing, Nothing) -> Right EQ
        (Nothing, Just _) -> Right LT
        (Just _, Nothing) -> Right GT
        (Just u, Just v) -> scalar u v
      _ -> Left ("no portable order for " ++ scalarName x)
    decimal c e = toRational c * (10 ^^ e)

listValue :: Type -> [Value] -> Value
listValue element = foldr cons (DataValue ty (Id "List::Nil") [])
  where
    ty = Constructor "List" [TypeArgument element]
    cons first rest = DataValue ty (Id "List::Cons") [first, rest]

listItems :: Value -> Either String [Value]
listItems root@(DataValue ty@(Constructor "List" [TypeArgument _]) _ _) = collect root
  where
    collect (DataValue actual (Id "List::Nil") []) | actual == ty = Right []
    collect (DataValue actual (Id "List::Cons") [first, rest]) | actual == ty =
      (first :) <$> collect rest
    collect _ = Left "invalid List constructor or tail"
listItems _ = Left "expected List"
