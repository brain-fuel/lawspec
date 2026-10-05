-- Reference execution of typed core. External calls are explicit effects;
-- evaluating a pure predicate cannot accidentally invoke an adapter.
module LawSpec.Core.Eval
  ( evaluate, evaluatePure, evaluateProposition
  , evaluateValue, evaluateValuePure, evaluateValueProposition, validateValueWithContracts
  ) where
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Core.Semantics
import LawSpec.Core.Types (TypeRegistry, makeRegistry)
import LawSpec.Core.Value
import qualified LawSpec.Core.Payload as Payload
import qualified Data.Map.Strict as M

type Adapter = Id -> [Scalar] -> Either String Scalar

evaluatePure :: Int -> [(Id,Scalar)] -> Expr -> Either String Scalar
evaluatePure bits = evaluate bits (\n _ -> Left ("external call in pure expression: " ++ idText n))

evaluate :: Int -> Adapter -> [(Id,Scalar)] -> Expr -> Either String Scalar
evaluate bits adapter bindings expr = do
  registry <- makeRegistry []
  value <- evaluateValue registry bits (scalarAdapter adapter)
    [(name, ScalarValue value) | (name, value) <- bindings] expr
  toScalarValue value

scalarAdapter :: Adapter -> Id -> [Value] -> Either String Value
scalarAdapter adapter name values = ScalarValue <$> (mapM toScalarValue values >>= adapter name)

type ValueAdapter = Id -> [Value] -> Either String Value

evaluateValuePure :: TypeRegistry -> Int -> [(Id,Value)] -> Expr -> Either String Value
evaluateValuePure registry bits = evaluateValue registry bits
  (\name _ -> Left ("external call in pure expression: " ++ idText name))

-- Constructor predicates are closed and pure; an adapter dispatcher must not
-- become available merely because a value crosses a definition boundary.
validateValueWithContracts :: TypeRegistry -> Int -> Type -> Value -> Either String Value
validateValueWithContracts registry bits =
  validateValueWith (evaluateValuePure registry bits) registry bits

evaluateValue :: TypeRegistry -> Int -> ValueAdapter -> [(Id,Value)] -> Expr -> Either String Value
evaluateValue registry bits adapter bindings = run (M.fromList bindings) where
  run env Expr{..} = context expressionOrigin $ let go = run env in case expressionNode of
    Constant s -> validateValueWithContracts registry bits expressionType (fromScalarValue expressionType s)
    Construct tag args -> do
      fields <- mapM go args
      validateValueWithContracts registry bits expressionType (DataValue expressionType tag fields)
    Match value cases -> do
      -- Program validation checks coverage and branch scopes; execution
      -- evaluates only the selected branch.
      payload <- go value
      case payload of
        DataValue _ tag fields -> case filter ((== tag) . caseConstructor) cases of
          [branch] | length fields == length (caseBinders branch) -> do
            checked <- sequence [validateValueWithContracts registry bits (binderType binder) field
              | (binder, field) <- zip (caseBinders branch) fields]
            result <- run (M.union (M.fromList (zip (map binderId (caseBinders branch)) checked)) env) (caseBody branch)
            validateValueWithContracts registry bits expressionType result
          _ -> Left "missing, duplicate, or malformed match branch"
        _ -> Left "matching requires a data value"
    AllElements value binder predicate -> do
      items <- go value >>= listItems
      let every _ [] = Right (ScalarValue (SBool True))
          every index (item:rest) = do
            accepted <- case do
              checked <- validateValueWithContracts registry bits (binderType binder) item
              run (M.insert (binderId binder) checked env) predicate >>= valueBoolean of
                Left message -> Left ("List element " ++ show index ++ ": " ++ message)
                Right result -> Right result
            if accepted then every (index + 1) rest else Right (ScalarValue (SBool False))
      every (0 :: Int) items
    AllPayloads value predicates -> do
      payload <- go value
      let check (binder,predicate) item = do
            checked <- validateValueWithContracts registry bits (binderType binder) item
            run (M.insert (binderId binder) checked env) predicate >>= valueBoolean
      accepted <- Payload.checkPayloads (validateValueWithContracts registry bits)
        registry (LawSpec.Core.expressionType value) (map check predicates) payload
      pure (ScalarValue (SBool accepted))
    Local n -> maybe (Left ("unbound core value: " ++ idText n))
      (validateValueWithContracts registry bits expressionType) (M.lookup n env)
    ExternalCall n args -> mapM go args >>= adapter n >>= validateValueWithContracts registry bits expressionType
    Binary op evidence a b -> do
      x <- go a
      y <- go b
      case evidence of
        Structural _ | op `elem` [Equal, NotEqual] -> do
          same <- equalValues bits x y
          pure (ScalarValue (SBool (if op == Equal then same else not same)))
        Structural _ -> Left "structural values support equality only"
        Numeric _ -> do
          left <- toScalarValue x
          right <- toScalarValue y
          ScalarValue <$> binaryValue bits (binaryName op) left right
    Unary Not a -> ScalarValue . SBool . not <$> (go a >>= valueBoolean)
    Unary Negate a -> do
      x <- go a >>= toScalarValue
      case x of
        SComplex t r i -> pure (ScalarValue (SComplex t (floatScalar (scalarName r) (negate (floatValue r))) (floatScalar (scalarName i) (negate (floatValue i)))))
        SFloat t _ -> pure (ScalarValue (floatScalar t (negate (floatValue x))))
        _ -> do r <- exactValue x; ScalarValue <$> convertValue bits expressionType (reduced (negate r))
    ShortCircuit And a b -> do x <- go a >>= valueBoolean; if x then go b else pure (ScalarValue (SBool False))
    ShortCircuit Or a b -> do x <- go a >>= valueBoolean; if x then pure (ScalarValue (SBool True)) else go b
    If c a b -> do x <- go c >>= valueBoolean; if x then go a else go b
    Convert _ target a -> do
      value <- go a
      if target == LawSpec.Core.expressionType a
        then validateValueWithContracts registry bits target value
        else fromScalarValue target <$> (toScalarValue value >>= convertValue bits target)
    -- An operation goes to the handler the caller installed in the hook.
    Perform op args -> mapM go args >>= adapter (operationId op) >>= validateValueWithContracts registry bits expressionType
    Handle _ _ -> Left "a failure is caught when the law runs, not by the compiler"
    Calls _ _ -> Left "calls are counted when the law runs, not by the compiler"
    Helper Unreachable _ -> Left "a branch the indices rule out was reached"
    Helper builtin args -> mapM go args >>= helper builtin
  helper Length [value@(DataValue (Constructor "List" [_]) _ _)] =
    ScalarValue . SInteger "Integer" . fromIntegral . length <$> listItems value
  helper IsPresent [PresenceValue _ payload] =
    Right (ScalarValue (SBool (case payload of Just _ -> True; Nothing -> False)))
  helper PresentValue [PresenceValue _ (Just value)] = Right value
  helper PresentValue [PresenceValue _ Nothing] = Left "presentValue requires a present value"
  helper Checked [_] = Right (ScalarValue (SBool True))
  helper Concurrently [value] = Right value
  helper Select [ScalarValue (SBool c), a, b] = Right (if c then a else b)
  helper Compare [a, b] = do
    order <- compareValues a b
    let ty = Constructor (collectionsUnit ++ "::type::Ordering") []
        tag = case order of LT -> "Less"; EQ -> "Equal"; GT -> "Greater"
    Right (DataValue ty (Id (collectionsUnit ++ "::type::Ordering::" ++ tag)) [])
  helper builtin values = ScalarValue <$> (mapM toScalarValue values >>= helperValue bits (builtinName builtin))
  context origin result = case result of
    Left msg -> Left (show origin ++ ": " ++ msg)
    Right v -> Right v

valueBoolean :: Value -> Either String Bool
valueBoolean (ScalarValue (SBool b)) = Right b
valueBoolean _ = Left "expected Bool"


evaluateProposition :: Int -> Adapter -> [(Id,Scalar)] -> Proposition -> Either String Bool
evaluateProposition bits adapter env proposition = do
  registry <- makeRegistry []
  evaluateValueProposition registry bits (scalarAdapter adapter)
    [(name, ScalarValue value) | (name, value) <- env] proposition

evaluateValueProposition :: TypeRegistry -> Int -> ValueAdapter -> [(Id,Value)] -> Proposition -> Either String Bool
evaluateValueProposition registry bits adapter env = go where
  term = evaluateValue registry bits adapter env
  go (Equation _ a b) = do x <- term a; y <- term b; equalValues bits x y
  go (Implication g p) = do enabled <- term g >>= valueBoolean; if enabled then go p else pure True
  go (Conjunction ps) = allM ps
  allM [] = Right True
  allM (p:ps) = do ok <- go p; if ok then allM ps else pure False
