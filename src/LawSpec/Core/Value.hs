-- Structural values in the reference interpreter. Scalar encodings remain
-- lossless leaves; algebraic constructors never share absence representations.
module LawSpec.Core.Value
  ( Value(..), fromScalarValue, toScalarValue, validateValue, validateValueWith, ValueCheck(..), checkValueWith
  , equalValues, listValue, listItems
  ) where

import Control.Monad (unless, zipWithM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import LawSpec.Core (Type(..), Argument(..), Id(..), Expr, binderId, binderType)
import LawSpec.Core.Types (TypeRegistry, checkType, constructorFieldsFor, constructorPredicatesFor)
import LawSpec.Core.Semantics (binaryValue)
import LawSpec.Scalar

data Value
  = ScalarValue Scalar
  | DataValue Type Id [Value]
  | PresenceValue Type (Maybe Value)
  deriving (Eq, Show)

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
          fields <- lift (constructorFieldsFor registry actual tag)
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
          pure (DataValue actual tag checked)

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
