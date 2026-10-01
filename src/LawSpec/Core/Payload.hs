-- Traverse stored type parameters without unfolding recursive declarations.
-- Plans retain parameter provenance: a fixed Int8 field is not a use of a
-- parameter merely because that parameter is instantiated with Int8.
module LawSpec.Core.Payload (checkPayloads) where

import Control.Monad (unless)
import LawSpec.Core
import LawSpec.Core.Types
import LawSpec.Core.Value (Value(..))
import qualified LawSpec.Core.Value as CoreValue
import LawSpec.Core.PayloadPlan (Plan(..))
import qualified LawSpec.Core.PayloadPlan as P

-- Validation is supplied by the reference evaluator so constructor contracts
-- run before payload predicates, without introducing a Value/Eval import cycle.
-- Every predicate belongs to the corresponding argument of the root type.
checkPayloads :: (Type -> Value -> Either String Value)
  -> TypeRegistry -> Type -> [Value -> Either String Bool] -> Value
  -> Either String Bool
checkPayloads validate registry root predicates value = do
  checkType registry root
  case root of
    Constructor name arguments -> do
      unless (length arguments == length predicates)
        (Left "payload predicate arity does not match type arguments")
      checked <- validate root value
      walk root (Applied name (map Parameter [0 .. length arguments - 1])) checked
    _ -> Left "payload predicates require an applied data type"
  where
    schema = P.fromRegistry registry

    walk _ Ignore _ = Right True
    walk _ (Parameter index) payload = predicates !! index $ payload
    walk expected (Applied name plans) payload = case (expected, payload) of
      (Constructor actual [TypeArgument element], PresenceValue valueType child)
        | name == actual && name `elem` ["Nullable", "Optional"] &&
          expected == valueType -> case plans of
            [plan] -> maybe (Right True) (walk element plan) child
            _ -> Left "invalid presence payload plan"
      (Constructor actual _, DataValue valueType tag fields)
        | name == actual && expected == valueType -> do
            instantiated <- constructorFieldsAt registry expected tag (map CoreValue.valueType fields)
            unless (length fields == length instantiated)
              (Left "payload constructor arity mismatch")
            children <- P.fields schema name tag plans
            every (zip3 instantiated children fields)
      _ -> Left "payload traversal requires a matching structural value"

    every [] = Right True
    every ((field, plan, payload):rest) = do
      accepted <- case walk (binderType field) plan payload of
        Left message -> Left (idText (binderId field) ++ ": " ++ message)
        Right result -> Right result
      if accepted then every rest else Right False
