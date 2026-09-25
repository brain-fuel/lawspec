module LawSpec.Compile (compile, prettyExpanded, metadataText, normal, compileWithProfile, typedExpression, validType, compileWithSettings) where

import LawSpec.Model
import LawSpec.Scalar
import LawSpec.Parser
import LawSpec.Refinement
import LawSpec.Eval
import LawSpec.Prelude
import Control.Monad.State.Strict
import Control.Monad (unless, when, zipWithM_, forM, forM_, foldM)
import qualified Data.Map.Strict as M
import Data.List (nub, intercalate, uncons)
import Data.Char (isLower)

data CS = CS { substitutions :: M.Map String Type, counter :: Int, obligations :: [Constraint], machineBits :: Int }
type C = StateT CS (Either String)
type Env = M.Map String Type
throwC :: String -> C a
throwC = lift . Left
withContext :: String -> C a -> C a
withContext prefix action = StateT $ \s -> case runStateT action s of
  Left err -> Left (prefix ++ err)
  Right result -> Right result
fresh :: C String
fresh = do s <- get; put s{counter=counter s+1}; pure (show (counter s))
resolve :: Type -> C Type
resolve (Variable n) = gets (M.lookup n . substitutions) >>= maybe (pure (Variable n)) resolve
resolve (Arrow a b) = Arrow <$> resolve a <*> resolve b
resolve (Applied n t) = Applied n <$> resolve t
resolve t = pure (baseType t)
occurs :: String -> Type -> Bool
occurs n (Variable m) = n == m
occurs n (Arrow a b) = occurs n a || occurs n b
occurs n (Applied _ t) = occurs n t
occurs _ _ = False
unify :: Type -> Type -> C ()
unify a b = do
  x <- resolve a; y <- resolve b
  case (x,y) of
    _ | x == y -> pure ()
    (Variable n,t) -> bind n t
    (t,Variable n) -> bind n t
    (Arrow p q,Arrow r s) -> unify p r >> unify q s
    (Applied n p, Applied m q) | n == m -> unify p q
    _ -> throwC ("type mismatch: " ++ prettyType x ++ " and " ++ prettyType y)
  where bind n t | occurs n t = throwC "infinite type"
                 | otherwise = modify (\s -> s{substitutions=M.insert n t (substitutions s)})
infer :: Env -> Expr -> C Type
infer env (Var n) = maybe (throwC ("unknown value: " ++ n)) (pure . baseType) (M.lookup n env)
infer _ (DecimalNumber _ _) = pure (Named "Decimal")
infer _ (Number _) = pure (Named "Integer")
infer _ (StringLit s) = do
  bits <- gets machineBits
  _ <- lift (validateScalar bits (textScalar s))
  pure (Named "Text")
infer _ (BoolLit _) = pure (Named "Bool")
infer _ (ScalarLit s) = do
  bits <- gets machineBits
  _ <- lift (validateScalar bits s)
  scalarType s
infer env (Annotate e t) = checkExpr env t e >> pure (baseType t)
infer _ (TypeBound _ t) = do
  t' <- resolve t
  modify (\s -> s{obligations=Capability "Bounded" t':obligations s})
  pure (Named "Integer")
infer env (Unary "!" e) = checkExpr env (Named "Bool") e >> pure (Named "Bool")
infer env (Unary "-" e) = do
  t <- infer env e >>= resolve
  case t of
    Named n | isNumeric n -> pure (Named (if isInteger n then "Integer" else n))
    Named n | take 1 n == "@" -> require "Integer" t >> pure (Named "Integer")
    _ -> throwC "negation requires a numeric operand"
infer _ (Unary _ _) = throwC "unknown unary operation"
infer env (Binary op a b) | op `elem` ["&&","||"] = checkExpr env (Named "Bool") a >> checkExpr env (Named "Bool") b >> pure (Named "Bool")
infer env (Binary op a b) = do
  (at,bt) <- operandTypes env a b
  case (at,bt) of
    _ | op `elem` ["==","!="], at == bt, not (case at of Named n -> isNumeric n; _ -> False) -> do
      modify (\s -> s{obligations=Capability "Eq" at:obligations s})
      pure (Named "Bool")
    (Named x,Named y) | take 1 x == "@" || take 1 y == "@" -> do
      let capability = if op `elem` ["==","!="] then "Eq" else if comparison op then "Ordered" else "Integer"
      require capability at
      require capability bt
      pure (Named (if comparison op then "Bool" else if op == "/" then "Rational" else "Integer"))
    (Named x,Named y) -> do
      result <- lift (promote op x y)
      when (op `elem` ["<","<=",">",">="] && result `elem` ["Complex64","Complex128"]) (throwC "complex values are not ordered")
      pure (Named (if op `elem` ["<","<=",">",">=","==","!="] then "Bool" else result))
    _ -> throwC "arithmetic requires concrete numeric operands after specialization"
infer env e@(Apply _ _) | (Var n,args) <- application e, take 8 n == "prelude." = builtin env (drop 8 n) args
infer env (Apply f x) = do
  ft <- infer env f >>= resolve
  case ft of
    Arrow a b -> checkExpr env a x >> resolve b
    _ -> do xt <- infer env x; r <- Variable . ("result:"++) <$> fresh; unify ft (Arrow xt r); resolve r
infer env (Compose f g) = do
  a <- Variable . ("a:"++) <$> fresh; b <- Variable . ("b:"++) <$> fresh; c <- Variable . ("c:"++) <$> fresh
  ft <- infer env f; gt <- infer env g
  unify ft (Arrow b c); unify gt (Arrow a b); pure (Arrow a c)
scalarType :: Scalar -> C Type
scalarType (SPresent n (Just v)) = Applied n <$> scalarType v
scalarType (SPresent n Nothing) = Applied n . Variable . ("presence:" ++) <$> fresh
scalarType s = pure (Named (scalarName s))
application :: Expr -> (Expr,[Expr])
application (Apply f x) = let (n,args) = application f in (n,args ++ [x])
application e = (e,[])
checkExpr :: Env -> Type -> Expr -> C ()
checkExpr env expected e = do
  t <- resolve (baseType expected)
  bits <- gets machineBits
  case (t,e) of
    (Named n,Number x) | isNumeric n -> lift (convertScalar bits n (SInteger "BigInt" x)) >> pure ()
    (Named n,DecimalNumber c e) | isNumeric n -> lift (convertScalar bits n (SDecimal c e)) >> pure ()
    (Named n,ScalarLit v) | isExact n && isExact (scalarName v) -> lift (convertScalar bits n v) >> pure ()
    (Applied "Nullable" _,ScalarLit (SAbsent "Null")) -> pure ()
    (Applied "Optional" _,ScalarLit (SAbsent "Undefined")) -> pure ()
    (Applied n a,ScalarLit (SPresent m (Just v))) | n == m -> checkExpr env a (ScalarLit v)
    (Applied n _,ScalarLit (SPresent m Nothing)) | n == m -> pure ()
    _ -> do
      actual <- infer env e >>= resolve
      case (t,actual) of
        (Named "Integer",Named m) | isInteger m -> pure ()
        -- Computed exact results use a checked adapter bridge at execution time.
        (Named n,Named m) | isExact n && m `elem` ["Integer","BigInt","Decimal","Rational"], not (isLiteral e) -> pure ()
        _ -> unify t actual
isLiteral :: Expr -> Bool
isLiteral (Number _) = True
isLiteral (DecimalNumber _ _) = True
isLiteral (ScalarLit _) = True
isLiteral (StringLit _) = True
isLiteral (BoolLit _) = True
isLiteral _ = False
operandTypes :: Env -> Expr -> Expr -> C (Type,Type)
operandTypes env a b = do
  at <- infer env a >>= resolve
  bt <- infer env b >>= resolve
  -- A declared floating context may type an otherwise exact numeric literal.
  let contextual t e fallback = case t of
        Named n | isInexact n && contextualNumber e -> checkExpr env t e >> pure t
        Applied _ _ | isLiteral e -> checkExpr env t e >> pure t
        _ -> pure fallback
  at' <- contextual bt a at
  bt' <- contextual at b bt
  pure (at',bt')
builtin :: Env -> String -> [Expr] -> C Type
builtin env n args
  | n == "checked", [a] <- args = infer env a >> pure (Named "Bool")
  | n `elem` ["isPresent","presentValue"], [a] <- args = do
      t <- infer env a >>= resolve
      case t of Applied _ inner -> pure (if n == "isPresent" then Named "Bool" else inner); _ -> throwC "presence helper requires Nullable or Optional"
  | n == "length", [a] <- args = do
      t <- infer env a >>= resolve
      unless (t `elem` map Named ["Text","CodePointText","Utf16Text","Bytes"]) (throwC "length requires a text or byte domain")
      pure (Named "Integer")
  | n `elem` ["real","imag"], [a] <- args = do
      t <- infer env a >>= resolve
      case t of Named "Complex64" -> pure (Named "Float32"); Named "Complex128" -> pure (Named "Float64"); _ -> throwC "real/imag require a complex operand"
  | n `elem` ["quot","rem"], [a,b] <- args = infer env (Binary n a b)
  | n `elem` ["isNaN","isInfinite","isFinite","isNegativeZero"], [a] <- args = do
      t <- infer env a >>= resolve
      unless (t `elem` map Named ["Float32","Float64"]) (throwC (n ++ " requires Float32 or Float64"))
      pure (Named "Bool")
  | n == "round", [a,scale] <- args = do
      t <- infer env a >>= resolve
      unless (case t of Named name -> isExact name; _ -> False) (throwC "round requires an exact value")
      checkExpr env (Named "Int32") scale
      pure (Named "Decimal")
  | Just p <- primitive n, isNumeric (primitiveName p), [a] <- args = do
      t <- infer env a >>= resolve
      unless (case t of Named name -> isNumeric name; _ -> False) (throwC "numeric conversion requires a numeric operand")
      pure (Named n)
  | otherwise = throwC ("unknown helper or wrong arity: prelude." ++ n)
-- The IR resolves every operation and the expected type of every adapter argument.
typedExpression :: Int -> [(String,Type)] -> Expr -> Either String TypedExpr
typedExpression bits env e = evalStateT (go Nothing e) (CS M.empty 0 [] bits)
  where
    context = M.fromList env
    go expected e = do
      natural <- infer context e >>= resolve
      case expected of Just targetType -> checkExpr context targetType e; Nothing -> pure ()
      let t = if isLiteral e then maybe natural id expected else natural
          conversion = case expected of Just targetType | targetType /= t -> Just targetType; _ -> Nothing
      children <- case e of
        Apply _ _ | (Var n,args) <- application e, take 8 n == "prelude." -> mapM (go Nothing) args
        Apply f x -> do
          ft <- infer context f >>= resolve
          case ft of Arrow a _ -> sequence [go Nothing f,go (Just a) x]; _ -> sequence [go Nothing f,go Nothing x]
        Binary _ a b -> do (at,bt) <- operandTypes context a b; sequence [go (Just at) a,go (Just bt) b]
        Unary _ a -> sequence [go Nothing a]
        Annotate a t' -> sequence [go (Just t') a]
        Compose f g -> sequence [go Nothing f,go Nothing g]
        _ -> pure []
      e' <- case e of TypeBound b ty -> lift (ScalarLit <$> boundsValue bits b ty); _ -> pure e
      pure (TypedExpr t e' children conversion)

rename :: String -> Type -> Type
rename p = mapType change (mapExprTypes (rename p)) where
  change (Variable n) = Variable (p ++ ":" ++ n)
  change t = t
renameConstraint :: String -> Constraint -> Constraint
renameConstraint p (Capability n t) = Capability n (rename p t)
require :: String -> Type -> C ()
require n t = modify (\s -> s{obligations=Capability n t:obligations s})
subst :: M.Map String Expr -> Expr -> Expr
subst m (Var n) = M.findWithDefault (Var n) n m
subst m (Apply f x) = Apply (subst m f) (subst m x)
subst m (Compose f g) = Compose (subst m f) (subst m g)
subst m (Binary op a b) = Binary op (subst m a) (subst m b)
subst m (Unary op a) = Unary op (subst m a)
subst m (Annotate a t) = Annotate (subst m a) t
subst _ e = e
normal :: Expr -> Expr
normal (Apply (Compose f g) x) = normal (Apply f (Apply g x))
normal (Apply f x) = Apply (normal f) (normal x)
normal (Compose f g) = Compose (normal f) (normal g)
normal (Binary op a b) = Binary op (normal a) (normal b)
normal (Unary op a) = Unary op (normal a)
normal (Annotate a t) = Annotate (normal a) t
normal e = e

type Table = M.Map (String,String) Law
expand :: Table -> String -> Env -> [String] -> Law -> [Expr] -> C ([Input], Assertion, [String])
expand table unit env stack law args = do
  let key = unit ++ "::" ++ lawName law
  when (key `elem` stack) (throwC ("recursive law expansion: " ++ intercalate " -> " (reverse (key:stack))))
  unless (length args == length (parameters law)) (throwC ("wrong argument count for law " ++ lawName law))
  p <- fresh
  let rt = rename p
  zipWithM_ (\(_,t) arg -> checkExpr env (rt t) arg) (parameters law) args
  modify (\s -> s{obligations=map (renameConstraint p) (requirements law) ++ obligations s})
  let replacements = M.fromList (zip (map fst (parameters law)) args)
      walk e m (Forall qs d) = do
        (bs,e',m') <- foldM (\(bs,scope,replacements') (n,t) -> do
          when (n `elem` map inputName bs) (throwC "duplicate quantified input")
          i <- ("_input"++) <$> fresh
          let renamed = rt t
              predicates = map (normal . subst (M.insert n (Var i) replacements')) (typePredicates (Var n) renamed)
          t' <- resolve renamed
          let scope' = M.insert i t' scope
          mapM_ (checkPredicate scope') predicates
          mapM_ (\(Capability c ty) -> resolve ty >>= require c) (typeConstraints renamed)
          pure (bs ++ [Input n i t' predicates],scope',M.insert n (Var i) replacements')) ([],e,m) qs
        (rest,body,tr) <- walk e' m' d
        pure (bs++rest,body,tr)
      walk e m (Equal a b) = do
        let l = normal (subst m (mapExprTypes rt a)); r = normal (subst m (mapExprTypes rt b))
        lt <- infer e l >>= resolve
        rt' <- infer e r >>= resolve
        case (lt,rt') of
          (Named ('@':_),Named b) | isNumeric b -> require "Integer" lt
          (Named a,Named ('@':_)) | isNumeric a -> require "Integer" rt'
          (Named a,Named b) | isNumeric a && isNumeric b -> do
            if contextualNumber l then checkExpr e rt' l else if contextualNumber r then checkExpr e lt r else lift (promote "==" a b) >> pure ()
          _ | isLiteral l -> checkExpr e rt' l
            | isLiteral r -> checkExpr e lt r
            | otherwise -> unify lt rt'
        modify (\s -> s{obligations=Capability "Eq" lt:obligations s})
        pure ([],AssertEqual l r,[])
      walk e m (Holds a) = walk e m (Equal a (BoolLit True))
      walk e m (Implies condition consequence) = do
        let guard = normal (subst m (mapExprTypes rt condition))
        infer e guard >>= unify (Named "Bool")
        (bs,body,tr) <- walk e m consequence
        pure (bs,AssertImplies guard body,tr)
      walk e m (And a b) = do
        (as,a',at) <- walk e m a
        (bs,b',bt) <- walk e m b
        pure (as++bs,AssertAll [a',b'],at++bt)
      walk e m (Invoke n as) = do
        (u,called) <- case M.lookup (unit,n) table of
          Just v -> pure (unit,v)
          Nothing -> maybe (throwC ("unknown law: " ++ n)) (pure . (,) "prelude") (M.lookup ("prelude",n) table)
        expand table u e (key:stack) called (map (subst m) as)
  (bs,body,tr) <- walk env replacements (definition law)
  pure (bs,body,(lawName law ++ concatMap ((" "++) . prettyExpr) args):tr)

unique :: String -> [String] -> Either String ()
unique kind xs = unless (length xs == length (nub xs)) (Left ("duplicate " ++ kind))
validType :: Type -> Bool
validType (Named n) = maybe False (const True) (primitive n)
validType (Applied n t) = n `elem` ["Nullable","Optional"] && scalar t
validType (Variable _) = True
validType (Arrow a b) = validType a && validType b
validType (Refined _ t _) = validType t
validType (Qualified _ t) = validType t
validType (CheckedType _ t) = validType t
validType _ = False
scalar :: Type -> Bool
scalar (Arrow _ _) = False
scalar t = validType t
validateUnit :: Unit -> Either [Diagnostic] ()
validateUnit u = either (Left . pure . (\m -> Diagnostic "declaration" m Nothing)) Right $ do
  unique "function" (map fst (functions u)); unique "law" (map lawName (laws u))
  forM_ (functions u) $ \(n,t) -> do
    unless (maybe False (isLower . fst) (uncons n)) (Left "function names must start with a lowercase letter")
    let (args,result) = functionType t
        concrete (Named name) = validType (Named name)
        concrete (Applied n t) = n `elem` ["Nullable","Optional"] && concrete t
        concrete _ = False
    unless (not (null args) && all concrete (result:args))
      (Left (n ++ ": functions require one or more concrete scalar inputs and a scalar result"))
  forM_ (laws u) $ \l -> do
    mapM_ (metadataText (map fst (parameters l ++ functions u))) [description l, rationale l]
    forM_ (examples l) $ \ex ->
      when (null (expectations ex)) (Left ("example " ++ exampleName ex ++ " requires at least one expect assertion; add expect <expression> = <literal>"))
    unique "parameter" (map fst (parameters l)); unique "example" (map exampleName (examples l))
    forM_ (parameters l) $ \(_,t) -> do
      let (args,result) = functionType t
      unless (all scalar (result:args)) (Left "law parameters must be scalars or curried functions between scalar types")
    unless (all (\(Capability _ t) -> scalar t) (requirements l)) (Left "capability requires a scalar type")
    unless (all (validType . snd) (parameters l) && all (\(Capability _ t) -> validType t) (requirements l)) (Left "unsupported type")

compile :: [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compile = compileWithProfile 64

compileWithProfile :: Int -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithProfile bits = compileWithSettings bits defaultGeneration

compileWithSettings :: Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithSettings bits settings sources = do
  unless (all (>0) [cases settings,maxAttempts settings,maxShrinks settings,exhaustiveLimit settings]) (Left [Diagnostic "generation" "generation limits must be positive integers" Nothing])
  unless (bits `elem` [32,64]) (Left [Diagnostic "machineBits" "machineBits must be 32 or 64" Nothing])
  parsed <- traverse parseSource (preludeSource:sources)
  us <- either (Left . pure . (\m -> Diagnostic "refinement" m Nothing)) Right (mapM lowerUnit parsed)
  unless (length us == length (nub (map unitName us))) (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  mapM_ validateUnit us
  let table = M.fromList [((unitName u,lawName l),l) | u <- us, l <- laws u]
  allExpanded <- forM [(u,l) | u <- us,l <- laws u] $ \(u,l) ->
    either (Left . pure . (\m -> Diagnostic "semantic" m (Just (location l)))) Right $ evalStateT (do
      let symbolic = not (null (parameters l))
          rigid (Variable n) = Named ("@" ++ n)
          rigid (Arrow a b) = Arrow (rigid a) (rigid b)
          rigid (Applied n t) = Applied n (rigid t)
          rigid t = if baseType t /= t then rigid (baseType t) else t
          env = M.fromList ([(n,rigid t) | (n,t) <- parameters l] ++ functions u)
      (bs0,body0,tr) <- expand table (unitName u) env [] l (map (Var . fst) (parameters l))
      bs <- mapM (\i -> do ps <- mapM resolveExpr (inputRefinements i); pure i{inputRefinements=ps}) bs0
      body <- resolveAssertion body0
      checkedInputs <- forM bs $ \v -> do
        t <- resolve (inputType v)
        unless (scalar t || (symbolic && symbolicScalar t)) (throwC ("unsupported quantified type: " ++ show t))
        when (not symbolic && not (concreteScalar t)) (throwC "executable inputs must have a concrete scalar type")
        pure v{inputType=t}
      os <- gets obligations >>= mapM (\(Capability c t) -> Capability c <$> resolve t)
      let allowed = [Capability c (rigid t) | Capability c t <- requirements l]
      forM_ os $ \c -> unless (satisfied bits allowed c) (throwC ("unsatisfied capability: " ++ show c))
      unless symbolic $ do
        when (null checkedInputs) (throwC "an executable law must quantify at least one scalar input")
        lift (unique "expanded input name" (map inputName checkedInputs))
      forM_ (examples l) $ \ex -> withContext ("example " ++ exampleName ex ++ ": ") $ do
        lift (unique "example binding" (map fst (bindings ex)))
        unless (M.keys (M.fromList (bindings ex)) == M.keys (M.fromList [(inputName v,()) | v <- checkedInputs])) (throwC ("example " ++ exampleName ex ++ " must bind exactly: " ++ intercalate ", " (map inputName checkedInputs)))
        forM_ (bindings ex) $ \(n,v) -> do
          case lookup n [(inputName inp,inputType inp) | inp <- checkedInputs] of
            Just expected -> checkExpr M.empty expected (literalExpr v)
            Nothing -> throwC "unknown example input"
        let exampleEnv = M.union (M.fromList [(inputName inp,inputType inp) | inp <- checkedInputs]) env
        forM_ (expectations ex) $ \check -> do
          actualType <- infer exampleEnv (actual check) >>= resolve
          checkExpr M.empty actualType (literalExpr (expected check))
      let (a,b,gs) = firstConclusion body
      let lawEnv = M.toList env ++ [(inputId inp,inputType inp) | inp <- checkedInputs]
          expressionEnv = lawEnv ++ [(inputName inp,inputType inp) | inp <- checkedInputs]
      ir <- if symbolic then pure [] else lift ((++) <$> mapM (typedExpression bits lawEnv) (concatMap inputRefinements checkedInputs ++ assertionExpressions body) <*> mapM (typedExpression bits expressionEnv) [actual c | ex <- examples l, c <- expectations ex])
      normalized <- if symbolic then pure (examples l) else forM (examples l) $ \ex -> do
        bs' <- forM (bindings ex) $ \(n,v) -> do
          t <- maybe (throwC "unknown example input") pure (lookup n [(inputName inp,inputType inp) | inp <- checkedInputs])
          value <- lift (normalizeLiteral bits t v)
          pure (n,value)
        checks' <- forM (expectations ex) $ \c -> do
          t <- infer (M.fromList expressionEnv) (actual c) >>= resolve
          value <- lift (normalizeLiteral bits t (expected c))
          pure c{expected=value}
        pure ex{bindings=bs',expectations=checks'}
      let resolvedInputs = [inp{inputRefinements=map (mapExprTypes resolveKnown) (inputRefinements inp)} | inp <- checkedInputs]
          resolveKnown t = t
      unless symbolic $ do
        mapM_ (validateExampleDomains bits lawEnv resolvedInputs) normalized
        validateFiniteDomain bits settings lawEnv resolvedInputs
      pure (Expanded (unitName u) (lawName l) resolvedInputs a b gs body tr l{examples=normalized} ir (if take 9 (lawName l) == "contract " then "contract" else "law") settings (map (planDomain [(inputId i,inputType i) | i <- resolvedInputs]) resolvedInputs))
      ) (CS M.empty 0 [] bits)
  mapM_ (validateContracts bits) us
  pure (filter ((/= "prelude") . unitName) us, filter (null . parameters . original) allExpanded)

prettyExpanded :: Expanded -> String
prettyExpanded e | propertyKind e == "contract" = description (original e)
prettyExpanded e = "for all " ++ intercalate " " ["(" ++ inputName i ++ " :: " ++ prettyType (inputType i) ++ (if null (inputRefinements i) then "" else " where " ++ intercalate " && " (map showExpr (inputRefinements i))) ++ ")" | i <- inputs e] ++ " . " ++ showAssertion (assertion e)
  where names = M.fromList [(inputId i,Var (inputName i)) | i <- inputs e]
        showExpr = prettyExpr . subst names
        showAssertion (AssertEqual a b) = showExpr a ++ " = " ++ showExpr b
        showAssertion (AssertImplies g a) = showExpr g ++ " implies " ++ showAssertion a
        showAssertion (AssertAll as) = intercalate " and " ["(" ++ showAssertion a ++ ")" | a <- as]

-- Braced references are checked against the law's lexical function environment.
metadataText :: [String] -> String -> Either String String
metadataText known = go
  where
    go [] = Right []
    go ('{':'{':rest) = ('{':) <$> go rest
    go ('}':'}':rest) = ('}':) <$> go rest
    go ('{':rest) = case break (== '}') rest of
      (n,'}':tail') | n `elem` known -> (n ++) <$> go tail'
      _ -> Left "unknown or unclosed metadata reference"
    go ('}':_) = Left "unmatched metadata brace; use }} for a literal brace"
    go (c:rest) = (c:) <$> go rest

concreteScalar :: Type -> Bool
concreteScalar (Named n) = validType (Named n)
concreteScalar (Applied n t) = n `elem` ["Nullable","Optional"] && concreteScalar t
concreteScalar _ = False

assertionExpressions :: Assertion -> [Expr]
assertionExpressions (AssertEqual a b) = [a,b]
assertionExpressions (AssertImplies g body) = g:assertionExpressions body
assertionExpressions (AssertAll as) = concatMap assertionExpressions as
normalizeLiteral :: Int -> Type -> Literal -> Either String Literal
normalizeLiteral bits t v = ScalarLiteral <$> normalize t (case v of DecimalLiteral c e -> SDecimal c e; IntLiteral n -> SInteger "BigInt" n; TextLiteral text -> textScalar text; BoolLiteral b -> SBool b; ScalarLiteral s -> s)
  where
    normalize (Named n) s = convertScalar bits n s
    normalize (Applied n _) (SAbsent a) | (n,a) `elem` [("Nullable","Null"),("Optional","Undefined")] = Right (SPresent n Nothing)
    normalize (Applied n _) (SPresent m Nothing) | n == m = Right (SPresent n Nothing)
    normalize (Applied n inner) (SPresent m (Just x)) | n == m = SPresent n . Just <$> normalize inner x
    normalize _ _ = Left "invalid contextual literal"

comparison :: String -> Bool
comparison op = op `elem` ["<","<=",">",">=","==","!="]

contextualNumber :: Expr -> Bool
contextualNumber (Number _) = True
contextualNumber (DecimalNumber _ _) = True
contextualNumber _ = False

symbolicScalar :: Type -> Bool
symbolicScalar (Named ('@':_)) = True
symbolicScalar (Applied n t) = n `elem` ["Nullable","Optional"] && symbolicScalar t
symbolicScalar t = concreteScalar t

checkPredicate :: Env -> Expr -> C ()
checkPredicate env e = do
  let names = exprVars e
  forM_ names $ \n -> when (take 8 n /= "prelude." && maybe False isFunction (M.lookup n env)) (throwC "adapter calls are forbidden in refinement predicates")
  checkExpr env (Named "Bool") e
  where isFunction (Arrow _ _) = True
        isFunction _ = False

satisfied :: Int -> [Constraint] -> Constraint -> Bool
satisfied bits allowed c@(Capability name t)
  | c `elem` allowed = True
  | name `elem` ["Eq","Ordered"], Capability "Integer" t `elem` allowed = True
  | otherwise = case baseType t of
      Named n -> case name of
        "Eq" -> validType t
        "Integer" -> isInteger n
        "Ordered" -> isNumeric n && n `notElem` ["Complex64","Complex128"]
        "Bounded" -> maybe False (const True) (integerBounds bits n)
        _ -> False
      Applied _ _ -> name == "Eq" && concreteScalar t
      _ -> False

validateContracts :: Int -> Unit -> Either [Diagnostic] ()
validateContracts bits u = either (Left . pure . (\m -> Diagnostic "contract" m Nothing)) Right $ forM_ (contracts u) $ \c -> evalStateT (do
  _ <- foldM (\env (n,t) -> do
    let env' = M.insert n (baseType t) env
    mapM_ (checkPredicate env') (typePredicates (Var n) t)
    mapM_ (\(Capability k ty) -> require k ty) (typeConstraints t)
    pure env') (M.fromList (functions u)) (contractArguments c)
  let env = M.fromList (functions u ++ [(n,baseType t) | (n,t) <- contractArguments c ++ [contractResult c]])
  mapM_ (checkPredicate env) (contractPostconditions c)
  mapM_ (\(Capability k ty) -> require k ty) (typeConstraints (snd (contractResult c)))
  os <- gets obligations
  forM_ os $ \o -> unless (satisfied bits [] o) (throwC ("unsatisfied contract capability: " ++ show o))
  ) (CS M.empty 0 [] bits)

validateExampleDomains :: Int -> [(String,Type)] -> [Input] -> Example -> C ()
validateExampleDomains bits env ins ex = withContext ("example " ++ exampleName ex ++ ": ") $ do
  let values = [(inputId i,s) | i <- ins, Just (ScalarLiteral s) <- [lookup (inputName i) (bindings ex)]]
  forM_ (concatMap inputRefinements ins) $ \p -> do
    ir <- lift (typedExpression bits env p)
    v <- lift (evaluateTyped bits values ir)
    unless (v == SBool True) (throwC ("example violates refinement: " ++ prettyExpr p))

validateFiniteDomain :: Int -> Generation -> [(String,Type)] -> [Input] -> C ()
validateFiniteDomain bits settings env ins = do
  let sets = mapM (finiteValues bits (exhaustiveLimit settings) . inputType) ins
  case sets of
    Just xs | product (map (toInteger . length) xs) <= toInteger (exhaustiveLimit settings) -> do
      predicates <- lift (mapM (typedExpression bits env) (concatMap inputRefinements ins))
      valid <- lift (mapM (\values -> foldM (\ok p -> if ok then (== SBool True) <$> evaluateTyped bits (zip (map inputId ins) values) p else Right False) True predicates) (sequence xs))
      unless (or valid) (throwC "empty executable refinement domain")
    _ -> forM_ (concatMap inputRefinements ins) $ \p -> when (null (filter ((/= "prelude.") . take 8) (exprVars p))) $ do
      ir <- lift (typedExpression bits env p)
      v <- lift (evaluateTyped bits [] ir)
      unless (v == SBool True) (throwC "empty executable refinement domain")

resolveExpr :: Expr -> C Expr
resolveExpr (TypeBound b t) = TypeBound b <$> resolve t
resolveExpr (Annotate e t) = Annotate <$> resolveExpr e <*> resolve t
resolveExpr (Apply a b) = Apply <$> resolveExpr a <*> resolveExpr b
resolveExpr (Compose a b) = Compose <$> resolveExpr a <*> resolveExpr b
resolveExpr (Binary op a b) = Binary op <$> resolveExpr a <*> resolveExpr b
resolveExpr (Unary op a) = Unary op <$> resolveExpr a
resolveExpr e = pure e
resolveAssertion :: Assertion -> C Assertion
resolveAssertion (AssertEqual a b) = AssertEqual <$> resolveExpr a <*> resolveExpr b
resolveAssertion (AssertImplies a b) = AssertImplies <$> resolveExpr a <*> resolveAssertion b
resolveAssertion (AssertAll xs) = AssertAll <$> mapM resolveAssertion xs
