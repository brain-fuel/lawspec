-- Surface type inference and contextual literal checking. This layer does not
-- expand laws or execute examples; elaboration consumes its typed expressions.
module LawSpec.Inference where

import LawSpec.Model
import LawSpec.Refinement (hasValueRefinements)
import LawSpec.Scalar
import LawSpec.Eval (boundsValue)
import Control.Monad (when, unless, zipWithM_, zipWithM, forM, forM_)
import Data.List (nub, isInfixOf)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified LawSpec.Core as Core
import LawSpec.Core.Types (builtinDataDeclarations, makeRegistry)

-- Givens are branch-local facts about rigid type variables: matching a GADT
-- constructor that refines `a` to Int32 makes @a resolve to Int32 there.
data CS = CS { substitutions :: M.Map String Type, counter :: Int, obligations :: [Constraint], machineBits :: Int, dataDeclarations :: [Core.DataDeclaration], givens :: M.Map String Type }
initialState :: Int -> CS
initialState bits = CS M.empty 0 [] bits [] M.empty

type C = StateT CS (Either String)
-- Only explicitly generalized declarations get fresh variables at each use.
-- Parameters and pattern binders are monomorphic, even when their types contain
-- inference variables or arrows.
data TypeScheme = Monomorphic Type | Universal [String] [Constraint] Type
  deriving (Eq, Show)
type Env = M.Map String TypeScheme

monoEnvironment :: [(String, Type)] -> Env
monoEnvironment = M.fromList . map (\(name, ty) -> (name, Monomorphic ty))

environmentTypes :: Env -> [(String, Type)]
environmentTypes = map (\(name, scheme) -> (name, schemeType scheme)) . M.toList

schemeType :: TypeScheme -> Type
schemeType (Monomorphic ty) = ty
schemeType (Universal _ _ ty) = ty

typeVariables :: Type -> [String]
typeVariables ty = nub $ case baseType ty of
  Variable name -> [name]
  Arrow a b -> typeVariables a ++ typeVariables b
  Applied _ a -> typeVariables a
  Application _ arguments -> concatMap typeVariables arguments
  _ -> []

definitionType :: FunctionDefinition -> Type
definitionType definition = foldr Arrow (functionResult definition)
  (map snd (functionArguments definition))

definitionEnvironment :: Unit -> Env
definitionEnvironment unit = M.union
  (M.fromList [(functionName definition, Universal (typeVariables (definitionType definition))
    (functionRequirements definition) (definitionType definition)) | definition <- functionDefinitions unit])
  (monoEnvironment (functions unit))

instantiate :: TypeScheme -> C Type
instantiate (Monomorphic ty) = pure (baseType ty)
instantiate (Universal variables constraints ty) = do
  unless (length variables == length (nub variables)) (throwC "duplicate quantified type variable")
  replacements <- mapM (\name -> do
    suffix <- fresh
    pure (name, Variable ("scheme:" ++ suffix))) variables
  let replace = mapType (\value -> case value of
        Variable name -> maybe value id (lookup name replacements)
        _ -> value) (mapExprTypes replace)
  mapM_ (\(Capability name target) -> require name (replace target)) constraints
  pure (baseType (replace ty))
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
resolve (Named ('@':n)) = gets (M.lookup n . givens) >>= maybe (pure (Named ('@':n))) resolve
resolve (Arrow a b) = Arrow <$> resolve a <*> resolve b
resolve (Applied n t) = Applied n <$> resolve t
resolve (Application n ts) = Application n <$> mapM resolve ts
resolve t = pure (baseType t)
occurs :: String -> Type -> Bool
occurs n (Variable m) = n == m
occurs n (Arrow a b) = occurs n a || occurs n b
occurs n (Applied _ t) = occurs n t
occurs n (Application _ ts) = any (occurs n) ts
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
    (Application n ps, Application m qs) | n == m && length ps == length qs -> zipWithM_ unify ps qs
    _ -> throwC ("type mismatch: " ++ prettyType x ++ " and " ++ prettyType y)
  where bind n t | occurs n t = throwC "infinite type"
                 | otherwise = modify (\s -> s{substitutions=M.insert n t (substitutions s)})
infer :: Env -> Expr -> C Type
infer env (Located _ e) = infer env e
infer env (Var n) = maybe (throwC ("unknown value: " ++ n)) instantiate (M.lookup n env)
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
infer env (ConstructLit name fields) = do
  (parameters, result) <- constructorSignature name
  unless (length parameters == length fields) (throwC ("wrong constructor arity: " ++ name))
  zipWithM_ (checkExpr env) parameters fields
  resolve result
infer env (AllPayloadsExpr value predicates) = do
  arguments <- infer env value >>= resolve >>= payloadArguments
  unless (length arguments == length predicates) (throwC "payload predicate arity mismatch")
  sequence_ [checkExpr (M.insert binder (Monomorphic argument) env) (Named "Bool") body
    | (argument,(binder,body)) <- zip arguments predicates]
  pure (Named "Bool")
infer env (AllElementsExpr value binder predicate) = do
  element <- Variable . ("element:" ++) <$> fresh
  infer env value >>= unify (Applied "List" element)
  resolved <- resolve element
  checkExpr (M.insert binder (Monomorphic resolved) env) (Named "Bool") predicate
  pure (Named "Bool")
infer env (MatchExpr value branches) = do
  scopes <- matchScopes env value branches
  result <- Variable . ("match:" ++) <$> fresh
  sequence_ [ do
      unless (M.null local) (throwC "a match that refines a type variable needs a known result type; annotate it or give the definition a signature")
      infer scope body >>= unify result
    | (Just (scope, local), MatchBranch _ _ body) <- zip scopes branches]
  resolve result
infer env (ListLit xs) = do
  element <- case xs of
    [] -> Variable . ("list:" ++) <$> fresh
    first:_ -> infer env first >>= resolve
  mapM_ (checkExpr env element) xs
  Applied "List" <$> resolve element
infer env (Annotate e t) = do
  when (hasValueRefinements t)
    (throwC "refinement predicates in expression annotations require checked contracts; use a quantified input or function signature")
  checkExpr env t e
  pure (baseType t)
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
      -- Equality on separate abstract types needs a shared numeric domain;
      -- independent Eq dictionaries do not establish cross-type equality.
      let capability = if op `elem` ["==","!="]
            then if at == bt then "Eq" else "Integer"
            else if comparison op
              then if at == bt || contextualNumber a || contextualNumber b
                then "Ordered" else "Integer"
              else "Integer"
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
application (Located _ e) = application e
application (Apply f x) = let (n,args) = application f in (n,args ++ [x])
application e = (e,[])
checkExpr :: Env -> Type -> Expr -> C ()
checkExpr env expected (Located _ e) = checkExpr env expected e
checkExpr env expected e = do
  t <- resolve (baseType expected)
  bits <- gets machineBits
  case (t,e) of
    (_,ConstructLit name fields) -> do
      parameters <- constructorParameters t name
      unless (length parameters == length fields) (throwC ("wrong constructor arity: " ++ name))
      zipWithM_ (checkExpr env) parameters fields
    (_,MatchExpr value branches) -> do
      scopes <- matchScopes env value branches
      sequence_ [withGivens local (checkExpr scope t body) | (Just (scope, local), MatchBranch _ _ body) <- zip scopes branches]
    (Applied "List" element,ListLit xs) -> mapM_ (checkExpr env element) xs
    (Named n,Number x) | isNumeric n -> lift (convertScalar bits n (SInteger "BigInt" x)) >> pure ()
    (Named n,DecimalNumber c e) | isNumeric n -> lift (convertScalar bits n (SDecimal c e)) >> pure ()
    (Named n,ScalarLit v) | isExact n && isExact (scalarName v) -> lift (convertScalar bits n v) >> pure ()
    (Applied "Nullable" _,ScalarLit (SAbsent "Null")) -> pure ()
    (Applied "Optional" _,ScalarLit (SAbsent "Undefined")) -> pure ()
    (Applied n a,ScalarLit (SPresent m (Just v))) | n == m -> checkExpr env a (ScalarLit v)
    (Applied n _,ScalarLit (SPresent m Nothing)) | n == m -> pure ()
    _ -> do
      actual <- infer env e
      checkInferred t e actual

-- Check the type already inferred for this occurrence. Re-inferring a universal
-- value here would create a different instantiation and lose its constraints.
checkInferred :: Type -> Expr -> Type -> C ()
checkInferred expected e inferred = do
  t <- resolve expected
  actual <- resolve inferred
  case (t,actual) of
    (Named "Integer",Named m) | isInteger m -> pure ()
    -- Computed exact results use a checked adapter bridge at execution time.
    (Named n,Named m) | isExact n && m `elem` ["Integer","BigInt","Decimal","Rational"], not (isLiteral e) -> pure ()
    _ -> unify t actual
isLiteral :: Expr -> Bool
isLiteral (Located _ e) = isLiteral e
isLiteral (Number _) = True
isLiteral (DecimalNumber _ _) = True
isLiteral (ScalarLit _) = True
isLiteral (StringLit _) = True
isLiteral (BoolLit _) = True
isLiteral (ListLit _) = True
isLiteral (ConstructLit _ _) = True
isLiteral _ = False
operandTypes :: Env -> Expr -> Expr -> C (Type,Type)
operandTypes env a b = do
  initialA <- infer env a
  initialB <- infer env b
  when (structuralLiteral a && structuralLiteral b) (unify initialA initialB)
  at <- resolve initialA
  bt <- resolve initialB
  -- A declared floating context may type an otherwise exact numeric literal.
  let contextual t e fallback = case t of
        Named n | isInexact n && contextualNumber e -> checkExpr env t e >> pure t
        Application _ _ | isLiteral e -> checkExpr env t e >> pure t
        Applied _ _ | isLiteral e -> checkExpr env t e >> pure t
        _ -> pure fallback
  at' <- contextual bt a at
  bt' <- contextual at b bt
  pure (at',bt')
builtin :: Env -> String -> [Expr] -> C Type
builtin env n args
  | n == "checked", [a] <- args = do
      t <- infer env a >>= resolve
      when (case t of Arrow _ _ -> True; _ -> False) (throwC "checked requires an evaluated scalar result, not a function")
      pure (Named "Bool")
  | n `elem` ["isPresent","presentValue"], [a] <- args = do
      t <- infer env a >>= resolve
      case t of Applied wrapper inner | wrapper `elem` ["Nullable","Optional"] -> pure (if n == "isPresent" then Named "Bool" else inner); _ -> throwC "presence helper requires Nullable or Optional"
  | n == "length", [a] <- args = do
      t <- infer env a >>= resolve
      unless (t `elem` map Named ["Text","CodePointText","Utf16Text","Bytes"] || case t of Applied "List" _ -> True; _ -> False)
        (throwC "length requires a List, text, or byte domain")
      pure (Named "Integer")
  | n `elem` ["real","imag"], [a] <- args = do
      t <- infer env a >>= resolve
      case t of Named "Complex64" -> pure (Named "Float32"); Named "Complex128" -> pure (Named "Float64"); _ -> throwC "real/imag require a complex operand"
  | n `elem` ["quot","rem","pow"], [a,b] <- args = infer env (Binary n a b)
  | n `elem` ["isNaN","isInfinite","isFinite","isNegativeZero"], [a] <- args = do
      t <- infer env a >>= resolve
      unless (t `elem` map Named ["Float32","Float64"]) (throwC (n ++ " requires Float32 or Float64"))
      pure (Named "Bool")
  | n == "round", [a,scale] <- args = do
      t <- infer env a >>= resolve
      case t of
        Named ('@':_) -> require "Integer" t
        _ -> unless (case t of Named name -> isExact name; _ -> False) (throwC "round requires an exact value")
      checkExpr env (Named "Int32") scale
      pure (Named "Decimal")
  | Just p <- primitive n, isNumeric (primitiveName p), [a] <- args = do
      t <- infer env a >>= resolve
      case t of
        Named ('@':_) -> require "Integer" t
        _ -> unless (case t of Named name -> isNumeric name; _ -> False) (throwC "numeric conversion requires a numeric operand")
      pure (Named n)
  | otherwise = throwC ("unknown helper or wrong arity: prelude." ++ n)
-- The IR resolves every operation and the expected type of every adapter argument.
typedExpression :: Int -> [(String,Type)] -> Expr -> Either String TypedExpr
typedExpression = typedExpressionWithData []

typedExpressionWithData :: [Core.DataDeclaration] -> Int -> [(String,Type)] -> Expr -> Either String TypedExpr
typedExpressionWithData declarations bits env expression =
  fst <$> typedExpressionWithSchemes declarations bits (monoEnvironment env) expression

typedExpressionWithSchemes :: [Core.DataDeclaration] -> Int -> Env -> Expr -> Either String (TypedExpr, [Constraint])
typedExpressionWithSchemes declarations bits env e = do
  _ <- makeRegistry declarations
  evalStateT (do
    expression <- go env Nothing e >>= resolveTree
    requirements <- gets obligations >>= mapM (\(Capability name ty) -> Capability name <$> resolve ty)
    pure (expression, nub requirements)) ((initialState bits){dataDeclarations=declarations})
  where
    go context expected (Located range e) = do
      value <- go context expected e
      pure value{expression=Located range (expression value)}
    go context expected e = do
      let descend = go context
      natural <- case (expected, e) of
        (Just targetType, ConstructLit _ _) -> checkExpr context targetType e >> resolve targetType
        (Just targetType, MatchExpr _ _) -> checkExpr context targetType e >> resolve targetType
        (Just targetType, ListLit _) -> checkExpr context targetType e >> resolve targetType
        _ -> do
          inferred <- infer context e
          case expected of
            Just targetType | isLiteral e -> checkExpr context targetType e
                            | otherwise -> checkInferred targetType e inferred
            Nothing -> pure ()
          resolve inferred
      t <- resolve (if isLiteral e then maybe natural id expected else natural)
      target <- traverse resolve expected
      let conversion = case target of Just targetType | targetType /= t -> Just targetType; _ -> Nothing
      children <- case e of
        AllPayloadsExpr value _ -> sequence [descend Nothing value]
        AllElementsExpr value _ _ -> sequence [descend Nothing value]
        MatchExpr value _ -> do
          valueType <- infer context value
          resolved <- resolve valueType
          sequence [descend (Just resolved) value]
        ConstructLit name fields -> do
          parameters <- constructorParameters t name
          sequence [descend (Just parameter) field | (parameter, field) <- zip parameters fields]
        ListLit xs -> case t of
          Applied "List" element -> mapM (descend (Just element)) xs
          _ -> throwC "list literal requires a List type"
        Apply _ _ | (Var n,args) <- application e, take 8 n == "prelude." -> mapM (descend Nothing) args
        Apply f x -> do
          ft <- infer context f >>= resolve
          case ft of
            Arrow a b -> do
              unify b natural
              checkExpr context a x
              function <- resolve ft
              sequence [descend (Just function) f,descend (Just a) x]
            _ -> sequence [descend Nothing f,descend Nothing x]
        Binary _ a b -> do (at,bt) <- operandTypes context a b; sequence [descend (Just at) a,descend (Just bt) b]
        Unary _ a -> sequence [descend Nothing a]
        Annotate a t' -> sequence [descend (Just t') a]
        Compose f g -> do
          composition <- resolve natural
          case composition of
            Arrow input output -> do
              middle <- Variable . ("composition:" ++) <$> fresh
              sequence [descend (Just (Arrow middle output)) f,
                descend (Just (Arrow input middle)) g]
            _ -> throwC "composition requires a function type"
        _ -> pure []
      e' <- case e of
        TypeBound b ty -> do
          resolved <- resolve ty
          case resolved of
            Named ('@':_) -> pure (TypeBound b resolved)
            _ -> lift (ScalarLit <$> boundsValue bits b resolved)
        _ -> pure e
      cases <- case e of
        AllPayloadsExpr value predicates -> do
          arguments <- infer context value >>= resolve >>= payloadArguments
          sequence [do
            body' <- go (M.insert binder (Monomorphic argument) context) (Just (Named "Bool")) body
            pure (TypedCase "" [(binder,argument)] body')
            | (argument,(binder,body)) <- zip arguments predicates]
        AllElementsExpr value binder predicate -> do
          valueType <- infer context value >>= resolve
          case valueType of
            Applied "List" element -> do
              body <- go (M.insert binder (Monomorphic element) context) (Just (Named "Bool")) predicate
              pure [TypedCase "" [(binder,element)] body]
            _ -> throwC "element predicate requires a List"
        -- Branches a GADT constructor cannot reach at this type are dropped,
        -- so a specialized instance never mentions them.
        MatchExpr value branches -> do
          scopes <- matchScopes context value branches
          sequence [withGivens local $ do
            types <- mapM (\name -> maybe (throwC "missing pattern binder") (resolve . schemeType) (M.lookup name scope)) names
            body' <- go scope (Just t) body
            pure (TypedCase tag (zip names types) body')
            | (Just (scope, local), MatchBranch tag names body) <- zip scopes branches]
        _ -> pure []
      pure (TypedExpr t e' children conversion cases)
    resolveTree (TypedExpr ty expression operands conversion cases) = do
      ty' <- resolve ty
      operands' <- mapM resolveTree operands
      conversion' <- traverse resolve conversion
      cases' <- mapM (\(TypedCase tag fields body) -> do
        fields' <- mapM (\(name, field) -> (,) name <$> resolve field) fields
        TypedCase tag fields' <$> resolveTree body) cases
      pure (TypedExpr ty' expression operands' conversion' cases')

require :: String -> Type -> C ()
require n t = modify (\s -> s{obligations=Capability n t:obligations s})

normal :: Expr -> Expr
normal (Located range e) = Located range (normal e)
normal (ConstructLit name fields) = ConstructLit name (map normal fields)
normal (AllPayloadsExpr value predicates) = AllPayloadsExpr (normal value) [(binder,normal body) | (binder,body) <- predicates]
normal (AllElementsExpr value binder predicate) = AllElementsExpr (normal value) binder (normal predicate)
normal (MatchExpr value branches) = MatchExpr (normal value) [MatchBranch tag names (normal body) | MatchBranch tag names body <- branches]
normal (ListLit xs) = ListLit (map normal xs)
normal (Apply f x) | Compose a b <- unlocated f = normal (Apply a (Apply b x))
normal (Apply f x) = Apply (normal f) (normal x)
normal (Compose f g) = Compose (normal f) (normal g)
normal (Binary op a b) = Binary op (normal a) (normal b)
normal (Unary op a) = Unary op (normal a)
normal (Annotate a t) = Annotate (normal a) t
normal e = e


comparison :: String -> Bool
comparison op = op `elem` ["<","<=",">",">=","==","!="]

contextualNumber :: Expr -> Bool
contextualNumber (Located _ e) = contextualNumber e
contextualNumber (Number _) = True
contextualNumber (DecimalNumber _ _) = True
contextualNumber _ = False


-- Instantiate constructor parameters freshly on every use. Shapes come from the
-- same built-in declarations that Core validates and the evaluator consumes.
constructorSignature :: String -> C ([Type], Type)
constructorSignature name = do
  declarations <- gets ((builtinDataDeclarations ++) . dataDeclarations)
  instantiateConstructor name declarations

instantiateConstructor :: String -> [Core.DataDeclaration] -> C ([Type], Type)
instantiateConstructor name declarations = do
  shape <- instantiateShape name declarations
  pure (shapeFields shape, shapeResult shape)

-- A fresh instance of a constructor: its fields and result over fresh
-- variables for the declaration's parameters and the constructor's
-- existentials. A GADT constructor's result applies its equations.
data ConstructorShape = ConstructorShape
  { shapeFields :: [Type], shapeResult :: Type
  , shapeArguments :: [(Type, Bool)]  -- each result argument, and whether an equation fixed it
  , shapeExistentials :: [String]
  -- Existentials no refinement mentions: only a value says what they are.
  , shapeFieldOnly :: [String] }

instantiateShape :: String -> [Core.DataDeclaration] -> C ConstructorShape
instantiateShape name declarations = case
  [(declaration, constructor) | declaration <- declarations,
    constructor <- Core.dataConstructors declaration,
    Core.constructorName constructor == name || Core.idText (Core.constructorId constructor) == name] of
  [(declaration, constructor)] -> do
    parameters <- mapM (\parameter -> do
      variable <- Variable . ("constructor:" ++) <$> fresh
      pure (parameter, variable)) (Core.dataParameters declaration)
    existentials <- mapM (\existential -> do
      variable <- ("exists:" ++) <$> fresh
      pure (existential, variable)) (Core.constructorExistentials constructor)
    let variables = parameters ++ [(e, Variable v) | (e, v) <- existentials]
        convert (Core.TypeVariable variable) = maybe (throwC "unbound constructor parameter") pure (lookup variable variables)
        convert (Core.Constructor constructorName args) = applyType constructorName <$> mapM argument args
        convert (Core.Arrow a b) = Arrow <$> convert a <*> convert b
        argument (Core.TypeArgument ty) = convert ty
        argument _ = throwC "indexed constructor requires indexed type inference"
    equations <- mapM (\(parameter, ty) -> (,) parameter <$> convert ty) (Core.constructorEquations constructor)
    let arguments = [maybe (variable, False) (\ty -> (ty, True)) (lookup parameter equations) | (parameter, variable) <- parameters]
        result = applyType (Core.idText (Core.dataId declaration)) (map fst arguments)
    fields <- mapM (convert . Core.binderType) (Core.constructorFields constructor)
    let mentioned = concatMap (coreVariables . snd) (Core.constructorEquations constructor)
        fieldOnly = [v | (e, v) <- existentials, e `notElem` mentioned]
    pure (ConstructorShape fields result arguments (map snd existentials) fieldOnly)
  [] -> throwC ("unknown constructor: " ++ name)
  _ -> throwC ("ambiguous constructor: " ++ name)
  where
    applyType name [] = Named name
    applyType name [argument] = Applied name argument
    applyType name arguments = Application name arguments

coreVariables :: Core.Type -> [Core.Id]
coreVariables ty = case ty of
  Core.TypeVariable v -> [v]
  Core.Constructor _ arguments -> concat [coreVariables t | Core.TypeArgument t <- arguments]
  Core.Arrow a b -> coreVariables a ++ coreVariables b

withGivens :: M.Map String Type -> C a -> C a
withGivens local action
  | M.null local = action
  | otherwise = do
      saved <- gets givens
      modify (\s -> s{givens = M.union local saved})
      result <- action
      modify (\s -> s{givens = saved})
      pure result

tryC :: C a -> C (Either String a)
tryC action = StateT $ \s -> case runStateT action s of
  Left message -> Right (Left message, s)
  Right (value, s') -> Right (Right value, s')

-- Matching a constructor against a scrutinee type: Nothing when the
-- constructor cannot build that type (the branch is inaccessible); otherwise
-- its field types and the givens its equations add for rigid variables.
-- Existentials the scrutinee does not determine become rigid in the branch.
matchConstructor :: Type -> String -> C (Maybe ([Type], M.Map String Type))
matchConstructor scrutinee tag = do
  declarations <- gets ((builtinDataDeclarations ++) . dataDeclarations)
  resolved <- resolve scrutinee
  let (parent, arguments) = case resolved of
        Named n -> (n, []); Applied n a -> (n, [a]); Application n as -> (n, as); _ -> ("", [])
      candidates = filter ((== parent) . Core.idText . Core.dataId) declarations
  shape <- instantiateShape tag (if null candidates then declarations else candidates)
  -- Core is monomorphic: a field whose type only its value knows has no
  -- type in a law or definition. Adapters receive such values natively.
  unless (null (shapeFieldOnly shape))
    (throwC ("matching " ++ tag ++ ", whose fields have existential types only a value determines, is supported only in adapters"))
  unless (length arguments == length (shapeArguments shape) || null candidates)
    (throwC ("constructor " ++ tag ++ " does not match " ++ prettyType resolved))
  saved <- gets givens
  outcome <- tryC $ do
    local <- fmap M.unions $ forM (zip arguments (shapeArguments shape)) $ \(argument, (pattern, refined)) -> do
      actual <- resolve argument
      case actual of
        Variable _ | refined -> throwC ("matching " ++ tag ++ " refines a type the context does not know; give the definition a signature")
        _ | refined -> refineTypes pattern actual
          | otherwise -> unify pattern actual >> pure M.empty
    forM_ (shapeExistentials shape) $ \v -> do
      t <- resolve (Variable v)
      case t of
        Variable free -> unify (Variable free) (Named ("@" ++ free))
        _ -> pure ()
    fields <- mapM resolve (shapeFields shape)
    pure (fields, local)
  modify (\s -> s{givens = saved})
  case outcome of
    Right found -> pure (Just found)
    Left message | "refines a type the context does not know" `isInfixOf` message -> throwC message
                 | otherwise -> pure Nothing

-- Unify a constructor's refinement with the scrutinee's argument; a rigid
-- variable met on either side is refined (a given) rather than unified.
refineTypes :: Type -> Type -> C (M.Map String Type)
refineTypes x y = do
  a <- resolve x
  b <- resolve y
  case (a, b) of
    _ | a == b -> pure M.empty
    (Named ('@':n), t) | refinable n -> given n t
    (t, Named ('@':n)) | refinable n -> given n t
    (Variable _, _) -> unify a b >> pure M.empty
    (_, Variable _) -> unify a b >> pure M.empty
    (Arrow p q, Arrow r s') -> M.union <$> refineTypes p r <*> refineTypes q s'
    (Applied n p, Applied m q) | n == m -> refineTypes p q
    (Application n ps, Application m qs) | n == m && length ps == length qs ->
      M.unions <$> zipWithM refineTypes ps qs
    _ -> throwC ("type mismatch: " ++ prettyType a ++ " and " ++ prettyType b)
  where
    refinable n = take 7 n /= "exists:"
    given :: String -> Type -> C (M.Map String Type)
    given n t = do
      modify (\s -> s{givens = M.insert n t (givens s)})
      pure (M.singleton n t)

constructorParameters :: Type -> String -> C [Type]
constructorParameters target name = do
  declarations <- gets ((builtinDataDeclarations ++) . dataDeclarations)
  resolved <- resolve target
  let parent = case resolved of Named n -> Just n; Applied n _ -> Just n; Application n _ -> Just n; _ -> Nothing
      candidates = maybe declarations (\n -> filter ((== n) . Core.idText . Core.dataId) declarations) parent
  (parameters, result) <- instantiateConstructor name candidates
  -- Bind fresh constructor variables to the caller's parameters, not the
  -- reverse: Core binders retain those declared parameter identities.
  unify result target
  mapM resolve parameters

-- Opposite sum constructors supply complementary type information. Infer both
-- in one substitution scope before assigning contextual types to either term.
structuralLiteral :: Expr -> Bool
structuralLiteral expression = case unlocated expression of
  ConstructLit _ _ -> True
  ListLit _ -> True
  _ -> False

jointStructuralContext :: Env -> Expr -> Expr -> C (Expr, Expr)
jointStructuralContext env a b
  | structuralLiteral a && structuralLiteral b = do
      left <- infer env a
      right <- infer env b
      unify left right
      context <- resolve left
      pure (Annotate a context, Annotate b context)
  | otherwise = pure (a,b)

contextualizeStructural :: Int -> [(String,Type)] -> Expr -> Expr -> Either String (Expr, Expr)
contextualizeStructural = contextualizeStructuralWithData []

contextualizeStructuralWithData :: [Core.DataDeclaration] -> Int -> [(String,Type)] -> Expr -> Expr -> Either String (Expr, Expr)
contextualizeStructuralWithData declarations bits env a b =
  evalStateT (jointStructuralContext (monoEnvironment env) a b) ((initialState bits){dataDeclarations=declarations})

-- Constructor coverage is checked while resolving branch environments and is
-- checked again independently at the Core boundary. Each branch is Nothing when
-- its GADT constructor cannot build the scrutinee's type, or its scope and the
-- givens it adds.
matchScopes :: Env -> Expr -> [MatchBranch] -> C [Maybe (Env, M.Map String Type)]
matchScopes env value branches = do
  ty <- infer env value >>= resolve
  let tags = [tag | MatchBranch tag _ _ <- branches]
  unless (length tags == length (nub tags)) (throwC "duplicate match constructor")
  resolved <- resolve ty
  known <- gets ((builtinDataDeclarations ++) . dataDeclarations)
  let parent = case resolved of Named n -> n; Applied n _ -> n; Application n _ -> n; _ -> ""
      declarations = [d | d <- known, Core.idText (Core.dataId d) == parent]
  declaration <- case declarations of
    [declaration] -> pure declaration
    _ -> throwC "matching requires a known data type"
  scopes <- mapM (scope ty) branches
  -- Every constructor that could build the scrutinee needs a branch.
  forM_ (Core.dataConstructors declaration) $ \c ->
    unless (any (`elem` tags) [Core.constructorName c, Core.idText (Core.constructorId c)]) $ do
      saved <- get
      reachable <- matchConstructor ty (Core.idText (Core.constructorId c))
      put saved
      when (reachable /= Nothing) (throwC "non-exhaustive match")
  pure scopes
  where
    scope ty (MatchBranch tag names _) = do
      unless (length names == length (nub names)) (throwC "duplicate match binder")
      found <- matchConstructor ty tag
      case found of
        Nothing -> pure Nothing
        Just (fields, local) -> do
          unless (length names == length fields) (throwC ("wrong match constructor arity: " ++ tag))
          pure (Just (M.union (monoEnvironment (zip names fields)) env, local))

-- Payload callbacks are scoped over declared type arguments, never over fixed
-- fields whose concrete types happen to coincide with an argument.
payloadArguments :: Type -> C [Type]
payloadArguments ty = do
  declarations <- gets ((builtinDataDeclarations ++) . dataDeclarations)
  (name,arguments) <- case baseType ty of
    Named name -> pure (name,[])
    Applied name argument -> pure (name,[argument])
    Application name arguments -> pure (name,arguments)
    _ -> throwC "payload predicates require a data type"
  count <- if name `elem` ["Nullable","Optional"] then pure 1 else
    case [length (Core.dataParameters d) | d <- declarations, Core.idText (Core.dataId d) == name] of
      [count] -> pure count
      _ -> throwC "payload predicates require a registered data type"
  unless (count == length arguments) (throwC "payload data type arity mismatch")
  pure arguments
