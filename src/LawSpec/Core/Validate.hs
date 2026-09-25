module LawSpec.Core.Validate (validateProgram, validateExpression, kindOf, operationEvidence) where

import LawSpec.Core
import LawSpec.Common
import LawSpec.Scalar
import LawSpec.Core.Semantics (convertValue)
import Control.Monad (unless, foldM)
import qualified Data.Map.Strict as M
import Data.List (nub)

type Scope = M.Map Id Type

-- Constructor signatures are kinded independently of source spelling. The
-- representation accepts arbitrary arity, including distinct index arguments.
kindOf :: [(String,Kind)] -> Type -> Either String Kind
kindOf registry ty = case ty of
  TypeVariable _ -> Right TypeKind
  Arrow a b -> do
    ka <- kindOf registry a; kb <- kindOf registry b
    unless (ka == TypeKind && kb == TypeKind) (Left "arrow operands must have kind Type")
    pure TypeKind
  Constructor n args -> do
    k <- maybe (Left ("unknown type constructor: " ++ n)) Right (lookup n registry)
    foldM apply k args
  where
    apply (KindArrow expected result) arg = do
      actual <- case arg of
        TypeArgument t -> kindOf registry t
        IndexArgument (Natural n) | n < 0 -> Left "natural index cannot be negative"
        IndexArgument _ -> Right ValueKind
      unless (actual == expected) (Left "type/index argument kind mismatch")
      pure result
    apply _ _ = Left "too many type arguments"
registry :: [(String,Kind)]
registry = [(primitiveName p,TypeKind) | p <- primitives] ++ [(n,KindArrow TypeKind TypeKind) | n <- ["Nullable","Optional"]]
checkType :: Type -> Either String ()
checkType t = do k <- kindOf registry t; unless (k == TypeKind) (Left "unsaturated type constructor")

operationEvidence :: BinaryOp -> Type -> Type -> Either String Evidence
operationEvidence op a b = case (a,b) of
  (Constructor x [],Constructor y []) | isNumeric x && isNumeric y -> do
    result <- promote (binaryName op) x y
    unless (not (op `elem` [Less,LessEqual,Greater,GreaterEqual] && result `elem` ["Complex64","Complex128"])) (Left "complex values are not ordered")
    pure (Numeric (scalarType result))
  _ | op `elem` [Equal,NotEqual], a == b -> checkType a >> pure (Structural a)
    | otherwise -> Left "invalid operation operand types"

validateExpression :: Int -> Scope -> Scope -> Expr -> Either String ()
validateExpression bits declarations scope expr@Expr{..} = do
  checkType expressionType
  mapM_ (validateExpression bits declarations scope) (children expr)
  actual <- case expressionNode of
    Constant s -> do
      canonical <- validateScalar bits s
      converted <- convertValue bits expressionType canonical
      unless (converted == canonical) (Left "core constant must already have its contextual representation")
      pure expressionType
    Local n -> maybe (Left ("unbound core binder: " ++ idText n)) Right (M.lookup n scope)
    ExternalCall n args -> do
      t <- maybe (Left ("unknown core declaration: " ++ idText n)) Right (M.lookup n declarations)
      let (parameters,result) = functionType t
      unless (parameters == map LawSpec.Core.expressionType args) (Left "core call argument types or arity do not match")
      pure result
    Binary op evidence a b -> do
      expected <- operationEvidence op (expressionTypeOf a) (expressionTypeOf b)
      unless (expected == evidence) (Left "invalid arithmetic/equality evidence")
      pure $ if isComparison op then scalarType "Bool" else case evidence of Numeric t -> t; Structural t -> t
    Unary Not a -> requireType "Bool" a >> pure (scalarType "Bool")
    Unary Negate a -> case expressionTypeOf a of
      Constructor n [] | isNumeric n -> pure (scalarType (if isInteger n then "Integer" else n))
      _ -> Left "numeric negation requires numeric operand"
    ShortCircuit _ a b -> mapM_ (requireType "Bool") [a,b] >> pure (scalarType "Bool")
    Convert mode target a -> do
      unless (target == expressionType) (Left "conversion result type mismatch")
      case (target,expressionTypeOf a) of
        (Constructor n [],Constructor m []) | isNumeric n && isNumeric m ->
          unless (mode == Explicit || isExact n && isExact m) (Left "checked adapter bridge requires exact operands")
        _ -> unless (target == expressionTypeOf a) (Left "invalid conversion types")
      pure target
    Helper builtin args -> helperType builtin args
  unless (actual == expressionType) (Left ("core result type mismatch: expected " ++ show actual ++ ", found " ++ show expressionType))
  where
    expressionTypeOf = LawSpec.Core.expressionType
    requireType n e = unless (expressionTypeOf e == scalarType n) (Left ("expected " ++ n))
    helperType Checked [_] = Right (scalarType "Bool")
    helperType Length [a] | expressionTypeOf a `elem` map scalarType ["Text","CodePointText","Utf16Text","Bytes"] = Right (scalarType "Integer")
    helperType IsPresent [a] | Constructor n [TypeArgument _] <- expressionTypeOf a, n `elem` ["Nullable","Optional"] = Right (scalarType "Bool")
    helperType PresentValue [a] | Constructor n [TypeArgument t] <- expressionTypeOf a, n `elem` ["Nullable","Optional"] = Right t
    helperType b [a] | b `elem` [RealPart,ImaginaryPart] = case expressionTypeOf a of
      Constructor "Complex64" [] -> Right (scalarType "Float32")
      Constructor "Complex128" [] -> Right (scalarType "Float64")
      _ -> Left "complex component helper requires complex value"
    helperType b [a] | b `elem` [IsNaN,IsInfinite,IsFinite,IsNegativeZero], expressionTypeOf a `elem` map scalarType ["Float32","Float64"] = Right (scalarType "Bool")
    helperType RoundHalfEven [a,b] | Constructor n [] <- expressionTypeOf a, isExact n = requireType "Int32" b >> pure (scalarType "Decimal")
    helperType _ _ = Left "invalid core helper arguments"

validateProgram :: Program -> Either [Diagnostic] ()
validateProgram Program{..} = either (Left . pure . (\m -> Diagnostic "core" m Nothing)) Right $ do
  unless (programMachineBits `elem` [32,64]) (Left "machineBits must be 32 or 64")
  let unitIds = map unitId programUnits
      propertyIds = [propertyId p | u <- programUnits,p <- unitProperties u]
  unless (length unitIds == length (nub unitIds) && length propertyIds == length (nub propertyIds)) (Left "duplicate core unit/property identity")
  let declarations = concatMap unitDeclarations programUnits
      ids = map declarationId declarations
      scope = M.fromList [(declarationId d,declarationType d) | d <- declarations]
  unless (length ids == length (nub ids)) (Left "duplicate core declaration identity")
  mapM_ (checkType . declarationType) declarations
  mapM_ (validateUnit scope) programUnits
  where
    expression = validateExpression programMachineBits
    extend scope b = do
      checkType (binderType b)
      unless (M.notMember (binderId b) scope) (Left "duplicate core binder identity")
      pure (M.insert (binderId b) (binderType b) scope)
    predicate ds scope p = do
      expression ds scope p
      unless (isPure p) (Left "external calls are forbidden in refinement predicates")
      unless (expressionType p == scalarType "Bool") (Left "proposition guard must be Bool")
    proposition ds scope p = case p of
      Equation ev a b -> do
        expression ds scope a; expression ds scope b
        expected <- operationEvidence Equal (expressionType a) (expressionType b)
        unless (ev == expected) (Left "invalid proposition equality evidence")
      Implication g body -> do
        expression ds scope g
        unless (expressionType g == scalarType "Bool") (Left "proposition guard must be Bool")
        proposition ds scope body
      Conjunction ps -> mapM_ (proposition ds scope) ps
    validateUnit ds u = do
      mapM_ (validateProperty ds) (unitProperties u)
      mapM_ (validateContract ds) (unitContracts u)
    validateProperty ds p = do
      scope <- foldM (\s q -> do
        next <- extend s (quantifiedBinder q)
        mapM_ (predicate ds next) (quantifiedPredicates q)
        mapM_ (\(op,e) -> do
          expression ds s e
          unless (op `elem` [Equal,Less,LessEqual,Greater,GreaterEqual]) (Left "invalid generator bound operator")
          unless (integerType (binderType (quantifiedBinder q)) && exactType (expressionType e)) (Left "generator bounds require an integer domain and exact value")
          unless (isPure e && totalBound e) (Left "generator bounds must be total pure expressions")) (quantifiedBounds q)
        pure next) M.empty (propertyInputs p)
      proposition ds scope (propertyBody p)
      mapM_ (validateExample ds scope) (propertyExamples p)
    validateExample ds scope e = do
      unless (M.keys (M.fromList (exampleBindings e)) == M.keys scope && length (exampleBindings e) == M.size scope) (Left "example must bind every input exactly once")
      mapM_ (\(i,v) -> do
        expression ds M.empty v
        unless (case expressionNode v of Constant _ -> True; _ -> False) (Left "example bindings must be concrete constants")
        unless (Just (expressionType v) == M.lookup i scope) (Left "example binding type mismatch")) (exampleBindings e)
      mapM_ (proposition ds scope) (exampleExpectations e)
    validateContract ds c = do
      declared <- maybe (Left "unknown contract declaration") Right (M.lookup (contractDeclaration c) ds)
      let (args,result) = functionType declared
      unless (args == map binderType (contractArguments c) && result == binderType (contractResult c)) (Left "contract signature mismatch")
      scope <- foldM extend M.empty (contractArguments c)
      mapM_ (predicate ds scope) (contractPreconditions c)
      scope' <- extend scope (contractResult c)
      mapM_ (predicate ds scope') (contractPostconditions c)

-- Bounds are evaluated before the full short-circuit predicate. Only total
-- exact arithmetic may move across that boundary; guards remain authoritative.
integerType, exactType :: Type -> Bool
integerType (Constructor n []) = isInteger n
integerType _ = False
exactType (Constructor n []) = isExact n
exactType _ = False
totalBound :: Expr -> Bool
totalBound e = case expressionNode e of
  Constant _ -> True
  Local _ -> True
  Unary Negate a -> exactType (expressionType a) && totalBound a
  Binary op _ a b | op `elem` [Add,Subtract,Multiply] -> all (\v -> exactType (expressionType v) && totalBound v) [a,b]
  Binary op _ a b | op `elem` [Divide,Quotient,Remainder], Constant v <- expressionNode b ->
    exactType (expressionType a) && totalBound a && either (const False) (/= 0) (exactValue v)
  Convert _ target a -> totalBound a && (target == expressionType a || integerType (expressionType a) && target `elem` map scalarType ["Integer","BigInt","Decimal","Rational"])
  _ -> False
