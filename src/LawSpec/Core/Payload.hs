{-# LANGUAGE FlexibleContexts #-}
-- | Traverse stored type parameters without unfolding recursive declarations.
-- Plans retain parameter provenance: a fixed Int8 field is not a use of a
-- parameter merely because that parameter is instantiated with Int8.
module LawSpec.Core.Payload (checkPayloads) where

import Control.Monad.Except (MonadError, liftEither, throwError, catchError)
import Control.Monad (unless)
import LawSpec.Core
import LawSpec.Core.Types
import LawSpec.Core.Value (Value(..))
import qualified LawSpec.Core.Value as CoreValue
import LawSpec.Core.PayloadPlan (Plan(..))
import qualified LawSpec.Core.PayloadPlan as P

-- | Validation is supplied by the reference evaluator so constructor contracts
-- run before payload predicates, without introducing a Value/Eval import cycle.
-- Every predicate belongs to the corresponding argument of the root type.
checkPayloads :: MonadError String m => (Type -> Value -> m Value)
  -> TypeRegistry -> Type -> [Value -> m Bool] -> Value
  -> m Bool
checkPayloads validate registry root predicates value = do
  liftEither (checkType registry root)
  case root of
    Constructor name arguments -> do
      unless (length arguments == length predicates)
        (throwError "payload predicate arity does not match type arguments")
      checked <- validate root value
      walk root (Applied name (map Parameter [0 .. length arguments - 1])) checked
    _ -> throwError "payload predicates require an applied data type"
  where
    schema = P.fromRegistry registry

    walk _ Ignore _ = pure True
    walk _ (Parameter index) payload = predicates !! index $ payload
    walk expected (Applied name plans) payload = case (expected, payload) of
      (Constructor actual [TypeArgument element], PresenceValue valueType child)
        | name == actual && name `elem` ["Nullable", "Optional"] &&
          expected == valueType -> case plans of
            [plan] -> maybe (pure True) (walk element plan) child
            _ -> throwError "invalid presence payload plan"
      (Constructor actual _, DataValue valueType tag fields)
        | name == actual && expected == valueType -> do
            instantiated <- liftEither (constructorFieldsAt registry expected tag (map CoreValue.valueType fields))
            unless (length fields == length instantiated)
              (throwError "payload constructor arity mismatch")
            children <- liftEither (P.fields schema name tag plans)
            every (zip3 instantiated children fields)
      _ -> throwError "payload traversal requires a matching structural value"

    every [] = pure True
    every ((field, plan, payload):rest) = do
      accepted <- catchError (walk (binderType field) plan payload)
        (throwError . ((idText (binderId field) ++ ": ") ++))
      if accepted then every rest else pure False
