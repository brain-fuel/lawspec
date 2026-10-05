module LawSpec.Core.Expression ( validateExpression, validateExpressionWithRegistry, kindOf, operationEvidence, operationEvidenceWithRegistry) where

import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Core.Types (kindOf)
import qualified LawSpec.Core.Types as Types
import LawSpec.Scalar
import LawSpec.Core.Semantics (convertValue)
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import Data.List (nub)

type Scope = M.Map Id Type

operationEvidence :: BinaryOp -> Type -> Type -> Either String Evidence
operationEvidence op a b = Types.makeRegistry [] >>= \registry -> operationEvidenceWithRegistry registry op a b

operationEvidenceWithRegistry :: Types.TypeRegistry -> BinaryOp -> Type -> Type -> Either String Evidence
operationEvidenceWithRegistry registry op a b = case (a,b) of
  (Constructor x [],Constructor y []) | isNumeric x && isNumeric y -> do
    result <- promote (binaryName op) x y
    unless (not (op `elem` [Less,LessEqual,Greater,GreaterEqual] && result `elem` ["Complex64","Complex128"])) (Left "complex values are not ordered")
    pure (Numeric (scalarType result))
  _ | op `elem` [Equal,NotEqual], a == b -> do
        obligations <- Types.equalityRequirements registry a
        unless (null obligations) (Left "unresolved equality capability in core operation")
        pure (Structural a)
    | otherwise -> Left "invalid operation operand types"

validateExpression :: Int -> Scope -> Scope -> Expr -> Either String ()
validateExpression bits declarations scope expr = Types.makeRegistry [] >>= \registry ->
  validateExpressionWithRegistry registry bits declarations scope expr

validateExpressionWithRegistry :: Types.TypeRegistry -> Int -> Scope -> Scope -> Expr -> Either String ()
validateExpressionWithRegistry registry bits declarations scope expr@Expr{..} = do
  Types.checkType registry expressionType
  case expressionNode of
    Match value _ -> validateExpressionWithRegistry registry bits declarations scope value
    AllElements value _ _ -> validateExpressionWithRegistry registry bits declarations scope value
    AllPayloads value _ -> validateExpressionWithRegistry registry bits declarations scope value
    _ -> mapM_ (validateExpressionWithRegistry registry bits declarations scope) (children expr)
  actual <- case expressionNode of
    Constant s -> do
      canonical <- validateScalar bits s
      converted <- convertValue bits expressionType canonical
      unless (converted == canonical) (Left "core constant must already have its contextual representation")
      pure expressionType
    Construct tag args -> do
      fields <- Types.constructorFieldsAt registry expressionType tag (map LawSpec.Core.expressionType args)
      unless (map binderType fields == map LawSpec.Core.expressionType args)
        (Left "constructor field types or arity do not match")
      pure expressionType
    Match value cases -> do
      declaration <- case expressionTypeOf value of
        Constructor name _ -> Types.lookupData registry (Id name)
        _ -> Left "matching requires a data type"
      -- A GADT constructor that cannot build this type has no branch.
      compatible <- Types.compatibleConstructors registry (expressionTypeOf value)
      let tags = map caseConstructor cases
          expected = map constructorId compatible
      unless (length tags == length (nub tags)) (Left "duplicate match constructor")
      unless (all (`elem` map constructorId (dataConstructors declaration)) tags) (Left "foreign match constructor")
      unless (all (`elem` expected) tags) (Left "inaccessible match constructor")
      unless (all (`elem` tags) expected) (Left "non-exhaustive match")
      mapM_ (validateCase (expressionTypeOf value)) cases
      pure expressionType
    AllElements value binder predicate -> do
      case expressionTypeOf value of
        Constructor "List" [TypeArgument element] ->
          unless (binderType binder == element) (Left "list predicate binder type mismatch")
        _ -> Left "element predicate requires a List"
      unless (M.notMember (binderId binder) scope) (Left "duplicate list predicate binder identity")
      validateExpressionWithRegistry registry bits declarations
        (M.insert (binderId binder) (binderType binder) scope) predicate
      requireType "Bool" predicate
      pure (scalarType "Bool")
    AllPayloads value predicates -> do
      arguments <- case expressionTypeOf value of
        Constructor name args -> do
          unless (name `elem` ["Nullable","Optional"]) $ do
            _ <- Types.lookupData registry (Id name)
            pure ()
          mapM (\argument -> case argument of
            TypeArgument ty -> Right ty
            _ -> Left "payload predicates require type arguments") args
        _ -> Left "payload predicates require an applied data type"
      unless (map (binderType . fst) predicates == arguments)
        (Left "payload predicate binder types or arity do not match")
      let ids = map (binderId . fst) predicates
      unless (length ids == length (nub ids) && all (`M.notMember` scope) ids)
        (Left "duplicate payload predicate binder identity")
      mapM_ (\(binder,predicate) -> do
        validateExpressionWithRegistry registry bits declarations
          (M.insert (binderId binder) (binderType binder) scope) predicate
        requireType "Bool" predicate) predicates
      pure (scalarType "Bool")
    Local n -> maybe (Left ("unbound core binder: " ++ idText n)) Right (M.lookup n scope)
    ExternalCall n args -> do
      t <- maybe (Left ("unknown core declaration: " ++ idText n)) Right (M.lookup n declarations)
      let (parameters,result) = functionType t
      unless (parameters == map LawSpec.Core.expressionType args) (Left "core call argument types or arity do not match")
      pure result
    Binary op evidence a b -> do
      expected <- operationEvidenceWithRegistry registry op (expressionTypeOf a) (expressionTypeOf b)
      unless (expected == evidence) (Left "invalid arithmetic/equality evidence")
      pure $ if isComparison op then scalarType "Bool" else case evidence of Numeric t -> t; Structural t -> t
    Unary Not a -> requireType "Bool" a >> pure (scalarType "Bool")
    Unary Negate a -> case expressionTypeOf a of
      Constructor n [] | isNumeric n -> pure (scalarType (if isInteger n then "Integer" else n))
      _ -> Left "numeric negation requires numeric operand"
    ShortCircuit _ a b -> mapM_ (requireType "Bool") [a,b] >> pure (scalarType "Bool")
    If c a b -> do
      requireType "Bool" c
      unless (expressionTypeOf a == expressionTypeOf b) (Left "if branches must have the same type")
      pure (expressionTypeOf a)
    Convert mode target a -> do
      unless (target == expressionType) (Left "conversion result type mismatch")
      case (target,expressionTypeOf a) of
        (Constructor n [],Constructor m []) | isNumeric n && isNumeric m ->
          unless (mode == Explicit || isExact n && isExact m) (Left "checked adapter bridge requires exact operands")
        _ -> unless (target == expressionTypeOf a) (Left "invalid conversion types")
      pure target
    -- An operation's types come from its ability (checked where the unit's
    -- abilities are known); raise's result takes whatever type it needs.
    Perform _ args -> do
      mapM_ (validateExpressionWithRegistry registry bits declarations scope) args
      pure expressionType
    Handle (CatchFailure (AbilityRef _ [failure])) body -> do
      validateExpressionWithRegistry registry bits declarations scope body
      pure (Constructor "Either" [TypeArgument failure, TypeArgument (expressionTypeOf body)])
    Handle _ _ -> Left "a handled failure names its type"
    Calls _ args -> do
      mapM_ (validateExpressionWithRegistry registry bits declarations scope) (maybe [] id args)
      pure (scalarType "Int64")
    -- An unreachable branch takes whatever type its context needs.
    Helper Unreachable [_] -> pure expressionType
    Helper builtin args -> helperType builtin args
  unless (actual == expressionType) (Left ("core result type mismatch: expected " ++ show actual ++ ", found " ++ show expressionType))
  where
    validateCase ty MatchCase{..} = do
      fields <- Types.constructorFieldsAt registry ty caseConstructor (map binderType caseBinders)
      unless (map binderType fields == map binderType caseBinders)
        (Left "match field types or arity do not match")
      let ids = map binderId caseBinders
      unless (length ids == length (nub ids) && all (`M.notMember` scope) ids)
        (Left "duplicate match binder identity")
      let branchScope = M.union (M.fromList [(binderId b, binderType b) | b <- caseBinders]) scope
      validateExpressionWithRegistry registry bits declarations branchScope caseBody
      unless (expressionTypeOf caseBody == expressionType) (Left "match branch result type mismatch")
    expressionTypeOf = LawSpec.Core.expressionType
    requireType n e = unless (expressionTypeOf e == scalarType n) (Left ("expected " ++ n))
    helperType Checked [_] = Right (scalarType "Bool")
    helperType Concurrently [a] = Right (expressionTypeOf a)
    helperType Select [c, a, b] | expressionTypeOf c == scalarType "Bool" && expressionTypeOf a == expressionTypeOf b =
      Right (expressionTypeOf a)
    helperType Compare [a, b] | expressionTypeOf a == expressionTypeOf b = do
      Types.keyedRequirements registry (expressionTypeOf a) >>= \needed ->
        unless (null needed) (Left "compare requires a type with a portable order")
      pure (Constructor (collectionsUnit ++ "::type::Ordering") [])
    helperType Length [a] | expressionTypeOf a `elem` map scalarType ["Text","CodePointText","Utf16Text","Bytes"] = Right (scalarType "Integer")
    helperType Length [a] | Constructor "List" [TypeArgument _] <- expressionTypeOf a = Right (scalarType "Integer")
    helperType IsPresent [a] | Constructor n [TypeArgument _] <- expressionTypeOf a, n `elem` ["Nullable","Optional"] = Right (scalarType "Bool")
    helperType PresentValue [a] | Constructor n [TypeArgument t] <- expressionTypeOf a, n `elem` ["Nullable","Optional"] = Right t
    helperType b [a] | b `elem` [RealPart,ImaginaryPart] = case expressionTypeOf a of
      Constructor "Complex64" [] -> Right (scalarType "Float32")
      Constructor "Complex128" [] -> Right (scalarType "Float64")
      _ -> Left "complex component helper requires complex value"
    helperType b [a] | b `elem` [IsNaN,IsInfinite,IsFinite,IsNegativeZero], expressionTypeOf a `elem` map scalarType ["Float32","Float64"] = Right (scalarType "Bool")
    helperType RoundHalfEven [a,b] | Constructor n [] <- expressionTypeOf a, isExact n = requireType "Int32" b >> pure (scalarType "Decimal")
    helperType b args = Left ("invalid arguments to " ++ builtinName b ++ ": " ++ show (map expressionTypeOf args))

