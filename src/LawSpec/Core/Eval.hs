{-# LANGUAGE FlexibleContexts #-}
-- | Reference execution of typed core. External calls are explicit effects;
-- evaluating a pure predicate cannot accidentally invoke an adapter.
module LawSpec.Core.Eval
  ( evaluate, evaluatePure, evaluateProposition
  , evaluateValueM, evaluateAdmittedValueM, evaluateValuePropositionM, validateValueWithContractsM
  , evaluateValue, evaluateValuePure, evaluateValueProposition, validateValueWithContracts
  ) where
import Control.Monad (forM)
import Control.Monad.Except (MonadError, liftEither, throwError, catchError)
import LawSpec.Collections (collectionsUnit)
import LawSpec.Common (Location(..), Span(..))
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Core.Semantics
import LawSpec.Core.Types (TypeRegistry, makeRegistry)
import LawSpec.Core.Value
import qualified LawSpec.Core.Payload as Payload
import qualified Data.Map.Strict as M
import Data.List (intercalate, isPrefixOf)

type Adapter = Id -> [Scalar] -> Either String Scalar

-- | A pure expression that reaches an adapter is a compiler bug, so it fails.
evaluatePure :: Int -> [(Id,Scalar)] -> Expr -> Either String Scalar
evaluatePure bits = evaluate bits (\n _ -> Left ("external call in pure expression: " ++ idText n))

-- | Scalar callers get the value evaluator behind a scalar interface.
evaluate :: Int -> Adapter -> [(Id,Scalar)] -> Expr -> Either String Scalar
evaluate bits adapter bindings expr = do
  registry <- makeRegistry []
  value <- evaluateValue registry bits (scalarAdapter adapter)
    [(name, ScalarValue value) | (name, value) <- bindings] expr
  toScalarValue value

scalarAdapter :: Adapter -> Id -> [Value] -> Either String Value
scalarAdapter adapter name values = ScalarValue <$> (mapM toScalarValue values >>= adapter name)

type ValueAdapter = Id -> [Value] -> Either String Value

-- | As evaluatePure, over structural values.
evaluateValuePure :: TypeRegistry -> Int -> [(Id,Value)] -> Expr -> Either String Value
evaluateValuePure registry bits = evaluateValue registry bits
  (\name _ -> Left ("external call in pure expression: " ++ idText name))

-- | Constructor predicates are closed and pure; an adapter dispatcher must not
-- become available merely because a value crosses a definition boundary.
validateValueWithContracts :: TypeRegistry -> Int -> Type -> Value -> Either String Value
validateValueWithContracts = validateValueWithContractsM (pure ())

validateValueWithContractsM :: MonadError String m => m () -> TypeRegistry -> Int -> Type -> Value -> m Value
validateValueWithContractsM tick registry bits =
  validateValueWithM tick (evaluateValueM tick registry bits (\name _ -> throwError ("external call in pure expression: " ++ idText name))) registry bits

validateConstructionWithContractsM :: MonadError String m => [Bool] -> m () -> TypeRegistry -> Int -> Type -> Value -> m Value
validateConstructionWithContractsM validated tick registry bits =
  validateConstructionWithM validated tick (evaluateValueM tick registry bits (\name _ -> throwError ("external call in pure expression: " ++ idText name))) registry bits

-- | The reference semantics of Core: every target must agree with it, and the
-- compiler uses it to check examples and enumerate finite domains.
-- ref:DEC-portable-exact-arithmetic
evaluateValue :: TypeRegistry -> Int -> ValueAdapter -> [(Id,Value)] -> Expr -> Either String Value
evaluateValue = evaluateValueM (pure ())

evaluateValueM :: MonadError String m => m () -> TypeRegistry -> Int -> (Id -> [Value] -> m Value)
  -> [(Id,Value)] -> Expr -> m Value
evaluateValueM = evaluateWithAdmissionM False

-- Only the admitted-definition interpreter uses this entry point. Its initial
-- arguments are validated at the public call boundary. Borrowed subvalues of
-- checked values need no second recursive validation; constructions and native
-- results still pass through their complete contract checks.
evaluateAdmittedValueM :: MonadError String m => m () -> TypeRegistry -> Int -> (Id -> [Value] -> m Value)
  -> [(Id,Value)] -> Expr -> m Value
evaluateAdmittedValueM = evaluateWithAdmissionM True

evaluateWithAdmissionM :: MonadError String m => Bool -> m () -> TypeRegistry -> Int -> (Id -> [Value] -> m Value)
  -> [(Id,Value)] -> Expr -> m Value
evaluateWithAdmissionM admitted tick registry bits adapter bindings = run (M.fromList bindings) where
  borrowed ty value = if admitted then pure value else validateValueWithContractsM tick registry bits ty value
  run env Expr{..} = context expressionOrigin $ tick >> (let go = run env in case expressionNode of
    Constant s -> validateValueWithContractsM tick registry bits expressionType (fromScalarValue expressionType s)
    Construct tag args -> do
      fields <- mapM go args
      -- A field this run built or took from a constant was validated in full
      -- a moment ago; an admitted definition's other values were validated
      -- at its boundary. Anything else is validated here.
      let built Expr{expressionNode = node} = case node of
            Construct _ _ -> True
            Constant _ -> True
            _ -> admitted
      validateConstructionWithContractsM (map built args) tick registry bits expressionType (DataValue expressionType tag fields)
    Match value cases -> do
      -- Program validation checks coverage and branch scopes; execution
      -- evaluates only the selected branch.
      payload <- go value
      case payload of
        DataValue _ tag fields -> case filter ((== tag) . caseConstructor) cases of
          [branch] | length fields == length (caseBinders branch) -> do
            checked <- sequence [borrowed (binderType binder) field
              | (binder, field) <- zip (caseBinders branch) fields]
            result <- run (M.union (M.fromList (zip (map binderId (caseBinders branch)) checked)) env) (caseBody branch)
            borrowed expressionType result
          _ -> throwError "missing, duplicate, or malformed match branch"
        _ -> throwError "matching requires a data value"
    Project _ index value -> do
      payload <- go value
      case payload of
        DataValue _ _ fields | (field : _) <- drop index fields -> borrowed expressionType field
        _ -> throwError "a field of a value without it"
    Update _ index value field -> do
      replacement <- go field
      payload <- go value
      case payload of
        DataValue t tag fields | index < length fields ->
          validateValueWithContractsM tick registry bits expressionType (DataValue t tag (take index fields ++ [replacement] ++ drop (index + 1) fields))
        _ -> throwError "a field of a value without it"
    AllElements value binder predicate -> do
      items <- go value >>= liftEither . listItems
      let every _ [] = pure (ScalarValue (SBool True))
          every index (item:rest) = do
            accepted <- catchError (do
              checked <- validateValueWithContractsM tick registry bits (binderType binder) item
              run (M.insert (binderId binder) checked env) predicate >>= liftEither . valueBoolean)
              (throwError . (("List element " ++ show index ++ ": ") ++))
            if accepted then every (index + 1) rest else pure (ScalarValue (SBool False))
      every (0 :: Int) items
    MapElements value binder body -> do
      items <- go value >>= liftEither . listItems
      results <- forM (zip [0 :: Int ..] items) $ \(index,item) -> catchError (do
        checked <- validateValueWithContractsM tick registry bits (binderType binder) item
        run (M.insert (binderId binder) checked env) body)
        (throwError . (("List element " ++ show index ++ ": ") ++))
      case expressionType of
        Constructor "List" [TypeArgument element] -> pure (listValue element results)
        _ -> throwError "a map over elements that is not a List"
    FilterElements value binder predicate -> do
      items <- go value >>= liftEither . listItems
      kept <- forM (zip [0 :: Int ..] items) $ \(index,item) -> catchError (do
        checked <- validateValueWithContractsM tick registry bits (binderType binder) item
        accepted <- run (M.insert (binderId binder) checked env) predicate >>= liftEither . valueBoolean
        pure [checked | accepted])
        (throwError . (("List element " ++ show index ++ ": ") ++))
      pure (listValue (binderType binder) (concat kept))
    SearchElements universal value binder predicate -> do
      items <- go value >>= liftEither . listItems
      let decisive = if universal then -1 else 1
          finished result = pure (ScalarValue (SInteger "Int8" result))
          search result [] = finished result
          search result (item : rest) = do
            checked <- validateValueWithContractsM tick registry bits (binderType binder) item
            outcome <- run (M.insert (binderId binder) checked env) predicate
            case outcome of
              ScalarValue (SInteger "Int8" code)
                | code == decisive -> finished code
                | code == 0 -> search 0 rest
                | code == negate decisive -> search result rest
              _ -> throwError "invalid finite search outcome"
      search (negate decisive) items
    AllPayloads value predicates -> do
      payload <- go value
      let check (binder,predicate) item = do
            checked <- validateValueWithContractsM tick registry bits (binderType binder) item
            run (M.insert (binderId binder) checked env) predicate >>= liftEither . valueBoolean
      accepted <- Payload.checkPayloads (validateValueWithContractsM tick registry bits)
        registry (LawSpec.Core.expressionType value) (map check predicates) payload
      pure (ScalarValue (SBool accepted))
    Local n -> maybe (throwError ("unbound core value: " ++ idText n))
      (borrowed expressionType) (M.lookup n env)
    ExternalCall n args -> mapM go args >>= adapter n >>= validateValueWithContractsM tick registry bits expressionType
    Binary op evidence a b -> do
      x <- go a
      y <- go b
      case evidence of
        Structural _ | op `elem` [Equal, NotEqual] -> do
          same <- liftEither (equalValues bits x y)
          pure (ScalarValue (SBool (if op == Equal then same else not same)))
        Structural _ -> throwError "structural values support equality only"
        Numeric _ -> do
          left <- liftEither (toScalarValue x)
          right <- liftEither (toScalarValue y)
          ScalarValue <$> liftEither (binaryValue bits (binaryName op) left right)
    Unary Not a -> ScalarValue . SBool . not <$> (go a >>= liftEither . valueBoolean)
    Unary Negate a -> do
      x <- go a >>= liftEither . toScalarValue
      case x of
        SComplex t r i -> pure (ScalarValue (SComplex t (floatScalar (scalarName r) (negate (floatValue r))) (floatScalar (scalarName i) (negate (floatValue i)))))
        SFloat t _ -> pure (ScalarValue (floatScalar t (negate (floatValue x))))
        _ -> do r <- liftEither (exactValue x); ScalarValue <$> liftEither (convertValue bits expressionType (reduced (negate r)))
    ShortCircuit And a b -> do x <- go a >>= liftEither . valueBoolean; if x then go b else pure (ScalarValue (SBool False))
    ShortCircuit Or a b -> do x <- go a >>= liftEither . valueBoolean; if x then pure (ScalarValue (SBool True)) else go b
    If c a b -> do x <- go c >>= liftEither . valueBoolean; if x then go a else go b
    Convert _ target a -> do
      value <- go a
      if target == LawSpec.Core.expressionType a
        then validateValueWithContractsM tick registry bits target value
        else fromScalarValue target <$> liftEither (toScalarValue value >>= convertValue bits target)
    -- An operation goes to the handler the caller installed in the hook.
    Perform op args -> mapM go args >>= adapter (operationId op) >>= validateValueWithContractsM tick registry bits expressionType
    Handle _ _ -> throwError "a failure is caught when the law runs, not by the compiler"
    Let binder value body -> do
      bound <- go value
      run (M.insert (binderId binder) bound env) body
    Calls _ _ -> throwError "calls are counted when the law runs, not by the compiler"
    Helper Unreachable _ -> throwError "a branch the indices rule out was reached"
    Helper IncompleteSearch [reason] -> do
      value <- go reason
      case value of
        ScalarValue (SSequence "Text" codePoints) -> throwError (map toEnum codePoints)
        _ -> throwError "quantifier-search-incomplete: invalid diagnostic reason"
    Helper builtin args -> mapM go args >>= liftEither . helper builtin)
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
  helper Recorded _ = Left "a recording is compared when the law runs, not by the compiler"
  helper b _ | b `elem` [AcquireResource, ReleaseResource, FreePort] = Left "a resource is acquired when the law runs, not by the compiler"
  -- Sequences: a List is a structure; Text and Bytes are scalars.
  helper Append [a@(DataValue (Constructor "List" [TypeArgument element]) _ _), b] = do
    xs <- listItems a
    ys <- listItems b
    Right (listValue element (xs ++ ys))
  helper Slice [x@(DataValue (Constructor "List" [TypeArgument element]) _ _), from, to] = do
    xs <- listItems x
    (i, j) <- sliceBounds (length xs) from to
    Right (listValue element (take (j - i) (drop i xs)))
  helper At [x@(DataValue (Constructor "List" [TypeArgument element]) _ _), i] = do
    xs <- listItems x
    n <- integerOf i
    Right (maybeValue element (if n >= 0 && n < fromIntegral (length xs) then Just (xs !! fromIntegral n) else Nothing))
  helper At [ScalarValue (SSequence "Bytes" units), i] = do
    n <- integerOf i
    let octet = scalarType "UInt8"
    Right (maybeValue octet (if n >= 0 && n < fromIntegral (length units) then Just (ScalarValue (SInteger "UInt8" (fromIntegral (units !! fromIntegral n)))) else Nothing))
  helper Range [ScalarValue (SInteger t lo), ScalarValue (SInteger _ hi)] =
    Right (listValue (scalarType t) [ScalarValue (SInteger t n) | n <- [lo .. hi - 1]])
  helper Octets [ScalarValue (SSequence "Bytes" units)] =
    Right (listValue (scalarType "UInt8") [ScalarValue (SInteger "UInt8" (fromIntegral u)) | u <- units])
  helper BytesOf [xs] = do
    items <- listItems xs
    units <- mapM integerOf items
    Right (ScalarValue (SSequence "Bytes" (map fromIntegral units)))
  helper Join [ScalarValue (SSequence "Text" separator), parts] = do
    items <- listItems parts
    texts <- mapM (\v -> case v of ScalarValue (SSequence "Text" t) -> Right t; _ -> Left "join needs texts") items
    Right (ScalarValue (SSequence "Text" (intercalate separator texts)))
  helper Split [ScalarValue (SSequence "Text" separator), ScalarValue (SSequence "Text" text)] =
    Right (texts (splitText separator text))
  helper Trim [ScalarValue (SSequence "Text" text)] = Right (ScalarValue (SSequence "Text" (trimText text)))
  helper IsUnicodeWhitespace [ScalarValue (SSequence "Text" text)] = Right (ScalarValue (SBool (all textWhiteSpace text)))
  helper TrimAsciiControl [ScalarValue (SSequence "Text" text)] = Right (ScalarValue (SSequence "Text" (trimAsciiControlText text)))
  helper Words [ScalarValue (SSequence "Text" text)] = Right (texts (wordsOfText text))
  helper Lines [ScalarValue (SSequence "Text" text)] = Right (texts (linesOfText text))
  helper builtin values = ScalarValue <$> (mapM toScalarValue values >>= helperValue bits (builtinName builtin))
  texts = listValue (scalarType "Text") . map (ScalarValue . SSequence "Text")
  integerOf v = case v of
    ScalarValue (SInteger _ n) -> Right n
    _ -> Left "expected an integer"
  sliceBounds count from to = do
    i <- integerOf from
    j <- integerOf to
    let clamp n = fromIntegral (max 0 (min (fromIntegral count) n))
    Right (clamp i, max (clamp i) (clamp j))
  maybeValue element value = case value of
    Just v -> DataValue (Constructor "Maybe" [TypeArgument element]) (Id "Maybe::Present") [v]
    Nothing -> DataValue (Constructor "Maybe" [TypeArgument element]) (Id "Maybe::Absent") []
  context origin result = catchError result $ \msg ->
    throwError (if any (`isPrefixOf` msg) ["quantifier-search-incomplete:", "evaluation-exhausted:"]
      then msg else originText origin ++ ": " ++ msg)

-- Internal constructors are never a user-facing source location.
originText :: Origin -> String
originText (SourceSpan range) = let at = spanStart range in
  file at ++ ":" ++ show (line at) ++ ":" ++ show (column at)
originText (GeneratedFrom identity) = "in " ++ idText identity

valueBoolean :: Value -> Either String Bool
valueBoolean (ScalarValue (SBool b)) = Right b
valueBoolean _ = Left "expected Bool"


-- | Scalar callers get the proposition evaluator behind a scalar interface.
evaluateProposition :: Int -> Adapter -> [(Id,Scalar)] -> Proposition -> Either String Bool
evaluateProposition bits adapter env proposition = do
  registry <- makeRegistry []
  evaluateValueProposition registry bits (scalarAdapter adapter)
    [(name, ScalarValue value) | (name, value) <- env] proposition

-- | Equations compare by LawSpec's equality, not a host language's.
-- ref:DEC-portable-exact-arithmetic
evaluateValueProposition :: TypeRegistry -> Int -> ValueAdapter -> [(Id,Value)] -> Proposition -> Either String Bool
evaluateValueProposition = evaluateValuePropositionM (pure ())

evaluateValuePropositionM :: MonadError String m => m () -> TypeRegistry -> Int -> (Id -> [Value] -> m Value)
  -> [(Id,Value)] -> Proposition -> m Bool
evaluateValuePropositionM tick registry bits adapter env = go where
  term = evaluateValueM tick registry bits adapter env
  go (Equation _ a b) = do x <- term a; y <- term b; liftEither (equalValues bits x y)
  go (Implication g p) = do enabled <- term g >>= liftEither . valueBoolean; if enabled then go p else pure True
  go (Conjunction ps) = allM ps
  go (Negation body) = not <$> go body
  go (Quantified _ _ _) = throwError "a quantified proposition requires a complete search plan before evaluation"
  allM [] = pure True
  allM (p:ps) = do ok <- go p; if ok then allM ps else pure False
