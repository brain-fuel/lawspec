-- | Surface type inference and contextual literal checking. This layer does not
-- expand laws or execute examples; elaboration consumes its typed expressions.
module LawSpec.Inference where

import LawSpec.Collections (collectionsUnit)
import LawSpec.Time (durationType, instantType)
import Data.List (stripPrefix)
import LawSpec.Model
import LawSpec.Refinement (hasValueRefinements, substituteType)
import LawSpec.Scalar
import LawSpec.Eval (boundsValue)
import Control.Monad (when, unless, zipWithM_, zipWithM, forM, forM_)
import Data.List (nub, isInfixOf, isPrefixOf, intercalate, sort, sortOn)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Control.Exception (evaluate)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.StableName (StableName, makeStableName)
import qualified LawSpec.Core as Core
import LawSpec.Core.Types (builtinDataDeclarations, makeRegistry)
import LawSpec.Core.Total (safeConversionTypes)
import qualified LawSpec.SourceContext as Source

-- | Givens are branch-local facts about rigid type variables: matching a GADT
-- constructor that refines `a` to Int32 makes @a resolve to Int32 there.
data CS = CS { substitutions :: M.Map String Type, counter :: Int, obligations :: [Constraint], machineBits :: Int, dataDeclarations :: [Core.DataDeclaration], givens :: M.Map String Type
             -- The declarations (built-in ones too) by type identity, and
             -- their constructors by name and by identity: a program may
             -- have thousands of types (withDataDeclarations sets both).
             , typesByName :: M.Map String [Core.DataDeclaration]
             , constructorsByName :: M.Map String [(Core.DataDeclaration, Core.DataConstructor)]
             , sourceContext :: Source.SourceContext }

-- | The state with these data declarations, indexed.
withDataDeclarations :: [Core.DataDeclaration] -> CS -> CS
withDataDeclarations declarations state = state
  { dataDeclarations = declarations, typesByName = types, constructorsByName = constructors }
  where (types, constructors) = dataIndex declarations

-- | The index of a program's declarations. Inference starts afresh for every
-- expression, so the last index built is kept, keyed by the declarations'
-- identity in memory (a pure function, so this is only a cache).
dataIndex :: [Core.DataDeclaration] -> (M.Map String [Core.DataDeclaration], M.Map String [(Core.DataDeclaration, Core.DataConstructor)])
dataIndex declarations = unsafePerformIO $ do
  _ <- evaluate declarations
  name <- makeStableName declarations
  cached <- readIORef dataIndexCache
  let ids = map Core.dataId declarations
  case cached of
    Just (key, keyIds, index) | key == name, keyIds == ids -> pure index
    _ -> do
      let known = builtinDataDeclarations ++ declarations
          index = ( M.fromListWith (flip (++)) [(Core.idText (Core.dataId d), [d]) | d <- known]
                  , M.fromListWith (flip (++)) (concat
                      [ [(Core.constructorName c, [(d, c)]) | Core.dataStructural d == Nothing] ++
                        [(Core.idText (Core.constructorId c), [(d, c)]) | Core.idText (Core.constructorId c) /= Core.constructorName c || Core.dataStructural d /= Nothing]
                      | d <- known, c <- Core.dataConstructors d ]) )
      writeIORef dataIndexCache (Just (name, ids, index))
      pure index
{-# NOINLINE dataIndex #-}

dataIndexCache :: IORef (Maybe (StableName [Core.DataDeclaration], [Core.Id], (M.Map String [Core.DataDeclaration], M.Map String [(Core.DataDeclaration, Core.DataConstructor)])))
dataIndexCache = unsafePerformIO (newIORef Nothing)
{-# NOINLINE dataIndexCache #-}

-- | The declarations of a type identity.
typesNamed :: String -> C [Core.DataDeclaration]
typesNamed parent = gets (M.findWithDefault [] parent . typesByName)
-- | Inference starts with no substitutions or obligations, and with the machine
-- profile, which decides the range of machine-sized literals.
-- ref:DEC-explicit-machine-profile
initialState :: Int -> CS
initialState bits = withDataDeclarations [] (CS M.empty 0 [] bits [] M.empty M.empty M.empty Source.emptyContext)

withSourceContext :: Source.SourceContext -> CS -> CS
withSourceContext context state = state { sourceContext=context }

-- | Inference fails with one message at the first error, which is what a
-- specification author needs; state carries the substitution and obligations.
type C = StateT CS (Either String)
-- | Only explicitly generalized declarations get fresh variables at each use.
-- Parameters and pattern binders are monomorphic, even when their types contain
-- inference variables or arrows.
data TypeScheme = Monomorphic Type | Universal [String] [Constraint] Type
  deriving (Eq, Show)
-- | Names map to schemes, so generic definitions are instantiated at each use.
type Env = M.Map String TypeScheme

-- | Law parameters and quantified inputs are monomorphic.
monoEnvironment :: [(String, Type)] -> Env
monoEnvironment = M.fromList . map (\(name, ty) -> (name, scheme ty))
  where
    -- A parameterized ability's operation keeps the ability's parameters as
    -- variables (LawSpec.Abilities), which each call instantiates.
    scheme ty = case filter (isPrefixOf "ability:") (typeVariables ty) of
      [] -> Monomorphic ty
      variables -> Universal variables [] ty

-- | Elaboration needs each name's type without its quantifiers.
environmentTypes :: Env -> [(String, Type)]
environmentTypes = map (\(name, scheme) -> (name, schemeType scheme)) . M.toList

-- | The declared type, before instantiation.
schemeType :: TypeScheme -> Type
schemeType (Monomorphic ty) = ty
schemeType (Universal _ _ ty) = ty

-- | A definition is generalised over the variables its signature mentions, in
-- order of appearance, so instantiation is predictable.
typeVariables :: Type -> [String]
typeVariables = typeVariableNames

-- | A definition is checked against the curried type its arguments and result
-- spell out.
definitionType :: FunctionDefinition -> Type
definitionType definition = foldr Arrow (functionResult definition)
  (map snd (functionArguments definition))

-- | Checked definitions are generic and adapters are not: an adapter is
-- implemented once per target at one type. ref:DEC-adapter-ownership
definitionEnvironment :: Unit -> Env
definitionEnvironment unit = M.union
  (M.fromList [(functionName definition, Universal (typeVariables (definitionType definition))
    (functionRequirements definition) (definitionType definition)) | definition <- functionDefinitions unit])
  (monoEnvironment (functions unit))

-- | Each use of a generic definition gets fresh variables and owes its
-- capability requirements again, so one use cannot constrain another.
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
-- | Inference errors are ordinary failures of the state's Either.
throwC :: String -> C a
throwC = lift . Left
-- | Errors deep in an expression are prefixed with where they occurred.
withContext :: String -> C a -> C a
withContext prefix action = StateT $ \s -> case runStateT action s of
  Left err -> Left (prefix ++ err)
  Right result -> Right result
-- | Variable names come from one counter, so they never collide within a check.
fresh :: C String
fresh = do s <- get; put s{counter=counter s+1}; pure (show (counter s))
-- | Given equations from a GADT match are consulted as well as the
-- substitution, so a refined variable resolves inside its branch.
-- ref:DEC-gadts-and-index-arithmetic
resolve :: Type -> C Type
resolve (Variable n) = gets (M.lookup n . substitutions) >>= maybe (pure (Variable n)) resolve
resolve (Named ('@':n)) = gets (M.lookup n . givens) >>= maybe (pure (Named ('@':n))) resolve
resolve (Arrow a b) = Arrow <$> resolve a <*> resolve b
resolve (Applied n t) = Applied n <$> resolve t
resolve (Application n ts) = Application n <$> mapM resolve ts
resolve t@(RecordShape fields) = checkRecordFields fields >> resolveRetained t
resolve t = pure (baseType t)

-- Intrinsic record restrictions belong to the product's type identity. The
-- ordinary scalar context erases refinements; resolving a stored field must
-- substitute through them, including any typed predicate annotations.
resolveRetained :: Type -> C Type
resolveRetained ty = do
  state <- get
  let replacements = M.union (substitutions state) (M.mapKeys ('@':) (givens state))
      walk seen current = do
        let next = substituteType replacements M.empty current
        if next == current then pure current else do
          when (next `elem` seen) (throwC "infinite type")
          walk (current:seen) next
  walk [] ty
-- | Binding a variable to a type that contains it would make an infinite type.
occurs :: String -> Type -> Bool
occurs name ty = name `elem` typeVariables ty
-- | First-order unification is enough: LawSpec has no higher-rank types, so
-- every law can be inferred without annotations beyond its signatures.
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
    (RecordShape fields,RecordShape others) -> sameRecordIndices x y >> unifyRecordFields fields others
    _ -> throwC ("type mismatch: " ++ prettyType x ++ " and " ++ prettyType y)
  where bind n t | occurs n t = throwC "infinite type"
                 | otherwise = modify (\s -> s{substitutions=M.insert n t (substitutions s)})

-- Closed products compare labels, stored types and restrictions. They never
-- acquire implicit width subtyping or a conversion from a nominal product.
sameRecordIndices :: Type -> Type -> C ()
sameRecordIndices a b=unless (recordIndexConditions a==recordIndexConditions b)
  (throwC "record index relationships differ")

unifyRecordFields :: [RecordField] -> [RecordField] -> C ()
unifyRecordFields left right = do
  checkRecordFields left
  checkRecordFields right
  unless (sort (map recordFieldLabel left) == sort (map recordFieldLabel right))
    (throwC "record types must have exactly the same fields")
  let forbidden = concatMap (typeValueVars . recordFieldType) (left ++ right)
      canonical label = head ["$record:" ++ label ++ replicate i '_' | i <- [0..],
        ("$record:" ++ label ++ replicate i '_') `notElem` forbidden]
      prepare fields = sortOn fst (walk [] fields)
      walk _ [] = []
      walk scope (field:rest) =
        let inner = (recordFieldBinding field,Var (canonical (recordFieldLabel field))) : scope
        in (recordFieldLabel field,replaceTypeValueVars inner (recordFieldType field)) : walk inner rest
  zipWithM_ (\(_,a) (_,b) -> stored a b) (prepare left) (prepare right)
  where
    stored a b = do
      x <- resolveRetained a
      y <- resolveRetained b
      case (x,y) of
        _ | x == y -> pure ()
        (Variable name,ty) -> bind name ty
        (ty,Variable name) -> bind name ty
        (Qualified _ ty,other) -> stored ty other
        (other,Qualified _ ty) -> stored other ty
        (Refined _ ty Nothing,other) -> stored ty other
        (other,Refined _ ty Nothing) -> stored other ty
        (Refined name ty predicate,Refined other target condition) -> do
          stored ty target
          resolved <- mapM resolveRetained [x,y]
          case resolved of
            [Refined name' _ predicate',Refined other' _ condition'] -> do
              let used = maybe [] exprVars predicate' ++ maybe [] exprVars condition'
                  local = head ["$record:refinement" ++ replicate i '_' | i <- [0..],
                    ("$record:refinement" ++ replicate i '_') `notElem` used]
                  normalize binder = fmap (stripLocations . replaceExprVars [(binder,Var local)])
              unless (normalize name' predicate' == normalize other' condition')
                (throwC "record field restrictions differ")
            _ -> throwC "lost a stored field refinement while resolving its type"
        (CheckedType checks ty,CheckedType conditions target) -> do
          stored ty target
          unless (map stripLocations checks == map stripLocations conditions)
            (throwC "record field argument checks differ")
        (Arrow p q,Arrow r s) -> stored p r >> stored q s
        (Applied name ty,Applied other target) | name == other -> stored ty target
        (Application name types,Application other targets) | name == other && length types == length targets ->
          zipWithM_ stored types targets
        (RecordShape fields,RecordShape others) -> sameRecordIndices x y >> unifyRecordFields fields others
        _ -> throwC ("record field type mismatch: " ++ prettyType x ++ " and " ++ prettyType y)
    bind name ty = do
      when (occurs name ty) (throwC "infinite type")
      modify (\state -> state{substitutions=M.insert name ty (substitutions state)})

checkRecordFields :: [RecordField] -> C ()
checkRecordFields fields = do
  let labels = map recordFieldLabel fields
      names = map recordFieldBinding fields
  unless (all (not . null) labels && length labels == length (nub labels))
    (throwC "duplicate or empty record field label")
  unless (all (not . null) names && length names == length (nub names))
    (throwC "duplicate or empty record field binding")
  mapM_ (nested . recordFieldType) fields
  where
    nested ty = case ty of
      RecordShape fields -> checkRecordFields fields
      Arrow a b -> nested a >> nested b
      Applied _ t -> nested t
      Application _ ts -> mapM_ nested ts
      Refined _ t _ -> nested t
      Qualified _ t -> nested t
      CheckedType _ t -> nested t
      _ -> pure ()

-- Intrinsic stored-field restrictions are enforced at checked construction.
-- An annotation cannot introduce a separate, unchecked value postcondition.
annotationRefinements :: Type -> Bool
annotationRefinements ty = case ty of
  RecordShape _ -> False
  Arrow a b -> annotationRefinements a || annotationRefinements b
  Applied _ t -> annotationRefinements t
  Application _ ts -> any annotationRefinements ts
  Qualified _ t -> annotationRefinements t
  other -> hasValueRefinements other
checkSelectionShapes :: Env -> [Expr] -> C ()
checkSelectionShapes env checks = mapM_ (checkExpr env (Named "Bool"))
  [check | check<-checks,Nothing<-[selectionBranchCheck check]]

checkSelectionBranches :: Env -> Type -> [Expr] -> C ()
checkSelectionBranches env result checks = mapM_ (checkExpr (M.insert selectionBranchResultName (Monomorphic result) env) result)
  [body | check<-checks,Just body<-[selectionBranchCheck check]]

-- | Types are inferred bottom up where literals do not need their context, so a
-- law reads without annotations. ref:DEC-readable-notation
infer :: Env -> Expr -> C Type
infer env (Located _ e) = infer env e
infer env e | Just (value,checks) <- selectionValidation e = do
  checkSelectionShapes env checks
  result <- infer env value >>= resolve
  checkSelectionBranches env result checks
  pure result
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
infer env (RecordLit fields) = do
  let labels = map fst fields
  unless (all (not . null) labels && length labels == length (nub labels))
    (throwC "duplicate or empty record value field")
  Record <$> mapM (\(name,value) -> RecordField name name <$> infer env value) fields
infer env (AllPayloadsExpr value predicates) = do
  arguments <- infer env value >>= resolve >>= payloadArguments
  unless (length arguments == length predicates) (throwC "payload predicate arity mismatch")
  sequence_ [checkExpr (M.insert binder (Monomorphic argument) env) (Named "Bool") body
    | (argument,(binder,body)) <- zip arguments predicates]
  pure (Named "Bool")
infer env (AllElementsExpr value binder predicate) = do
  (_,element) <- iterationTypes env value binder predicate
  checkExpr (M.insert binder (Monomorphic element) env) (Named "Bool") predicate
  pure (Named "Bool")
infer env (MatchExpr value branches) = do
  scopes <- matchScopes env value branches
  result <- Variable . ("match:" ++) <$> fresh
  let live = [(scope, local, body) | (Just (scope, local), MatchBranch _ _ body) <- zip scopes branches]
      literal (_, _, body) = numericLiteral body
      -- A numeric literal branch takes its type from the other branches,
      -- as `| Nothing -> 0 | Just n -> n` is an Int64 when n is.
      ordered = filter (not . literal) live ++ filter literal live
      typed = not (all literal live)
  forM_ live $ \(_, local, _) ->
    unless (M.null local) (throwC "a match that refines a type variable needs a known result type; annotate it or give the definition a signature")
  sequence_ [ if typed && literal branch then resolve result >>= \t -> checkExpr scope t body else infer scope body >>= unify result
    | branch@(scope, _, body) <- ordered ]
  resolve result
infer env (ListLit xs) = do
  -- The first item that is not a numeric literal gives the others' type.
  element <- case filter (not . numericLiteral) xs ++ xs of
    [] -> Variable . ("list:" ++) <$> fresh
    first:_ -> infer env first >>= resolve
  mapM_ (checkExpr env element) xs
  Applied "List" <$> resolve element
infer env (Annotate e t) = do
  when (annotationRefinements t)
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
  (at,bt) <- operationOperandTypes env op a b
  -- Structural equality relates one type: Right 1 == positive x fixes the
  -- error type of Right 1. Numbers keep their promotion rules.
  let structural t = case t of
        Named n -> not (isNumeric n) && take 1 n /= "@"
        _ -> True
  case (at,bt) of
    _ | op `elem` ["==","!="], at == bt || (structural at && structural bt)
      , not (case at of Named n -> isNumeric n; _ -> False) -> do
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
    -- An instant moves by a duration, two instants are a duration apart,
    -- and instants compare (LawSpec.Builtins' clock).
    (Named x,Named y) | instantType `elem` [x,y] -> case op of
      _ | op `elem` ["+","-"], x == instantType, y == durationType -> pure (Named instantType)
        | op == "+", x == durationType, y == instantType -> pure (Named instantType)
        | op == "-", x == instantType, y == instantType -> pure (Named durationType)
        | comparison op, x == y -> pure (Named "Bool")
      _ -> throwC ("instants support + and - with durations, - and comparisons with instants, not " ++ op ++ " on " ++ x ++ " and " ++ y)
    -- Durations add, subtract, scale and divide by whole numbers, and
    -- compare; LawSpec.Time elaborates each to a checked definition.
    (Named x,Named y) | durationType `elem` [x,y] -> case op of
      _ | op `elem` ["+","-"], x == y -> pure (Named durationType)
        | op == "*", x == durationType, isInteger y -> pure (Named durationType)
        | op == "*", y == durationType, isInteger x -> pure (Named durationType)
        | op == "quot", x == durationType, isInteger y -> pure (Named durationType)
        | comparison op, x == y -> pure (Named "Bool")
      _ -> throwC ("durations support +, - and comparisons with durations, and * and prelude.quot with whole numbers, not " ++ op ++ " on " ++ x ++ " and " ++ y)
    (Named x,Named y) -> do
      result <- lift (promote op x y)
      when (op `elem` ["<","<=",">",">="] && result `elem` ["Complex64","Complex128"]) (throwC "complex values are not ordered")
      pure (Named (if op `elem` ["<","<=",">",">=","==","!="] then "Bool" else result))
    _ -> throwC "arithmetic requires concrete numeric operands after specialization"
infer env e@(Apply _ _) | isFieldNode e = fieldType env e
infer env e@(Apply _ _) | (Var n,args) <- application e, take 8 n == "prelude." = builtin env (drop 8 n) args
-- Numeric literals are checked after the other arguments, so a polymorphic
-- parameter takes its type from them: prelude.insert 1 s with s :: Set Int32
-- reads 1 as an Int32, not an Integer.
infer env e@(Apply _ _)
  | (f, args@(_ : _ : _)) <- application e, any numericLiteral args, not (all numericLiteral args) = do
      ft <- infer env f >>= resolve
      case arrows (length args) ft of
        Just (parameters, result) -> do
          let pairs = zip parameters args
          mapM_ (\(t, a) -> checkExpr env t a) [p | p@(_, a) <- pairs, not (numericLiteral a)]
          mapM_ (\(t, a) -> checkExpr env t a) [p | p@(_, a) <- pairs, numericLiteral a]
          resolve result
        Nothing -> applyInOrder ft (args)
  where
    arrows 0 t = Just ([], t)
    arrows n (Arrow a b) = (\(as, r) -> (a : as, r)) <$> arrows (n - 1 :: Int) b
    arrows _ _ = Nothing
    applyInOrder ft [] = pure ft
    applyInOrder ft (x : xs) = do
      ft' <- resolve ft
      next <- case ft' of
        Arrow a b -> checkExpr env a x >> resolve b
        _ -> do xt <- infer env x; r <- Variable . ("result:"++) <$> fresh; unify ft' (Arrow xt r); resolve r
      applyInOrder next xs
infer env (Apply f x) = do
  ft <- infer env f >>= resolve
  case ft of
    Arrow a b -> checkExpr env a x >> resolve b
    _ -> do xt <- infer env x; r <- Variable . ("result:"++) <$> fresh; unify ft (Arrow xt r); resolve r
infer env (Compose f g) = do
  a <- Variable . ("a:"++) <$> fresh; b <- Variable . ("b:"++) <$> fresh; c <- Variable . ("c:"++) <$> fresh
  ft <- infer env f; gt <- infer env g
  unify ft (Arrow b c); unify gt (Arrow a b); pure (Arrow a c)
-- | A literal value's type is its declared scalar type; an absent optional
-- value's element type is left to inference.
scalarType :: Scalar -> C Type
scalarType (SPresent n (Just v)) = Applied n <$> scalarType v
scalarType (SPresent n Nothing) = Applied n . Variable . ("presence:" ++) <$> fresh
scalarType s = pure (Named (scalarName s))
-- | Check an application against an expected type: the function's result
-- first, then its other arguments, then its numeric literals.
checkApplication :: Env -> Type -> Expr -> C Type
checkApplication env expected e = do
  let (f, args) = application e
  ft <- infer env f >>= resolve
  case arrows (length args) ft of
    Just (parameters, result) -> do
      checkInferred expected e result
      let pairs = zip parameters args
      mapM_ (\(t, a) -> checkExpr env t a) [p | p@(_, a) <- pairs, not (numericLiteral a)]
      mapM_ (\(t, a) -> checkExpr env t a) [p | p@(_, a) <- pairs, numericLiteral a]
      resolve result
    Nothing -> do
      inferred <- infer env e
      checkInferred expected e inferred
      resolve inferred
  where
    arrows 0 t = Just ([], t)
    arrows n (Arrow a b) = (\(as, r) -> (a : as, r)) <$> arrows (n - 1 :: Int) b
    arrows _ _ = Nothing

-- | A numeric literal takes its type from its context, as 1 is an Int8 or a
-- Float64 where one is expected.
numericLiteral :: Expr -> Bool
numericLiteral e = case e of
  Located _ inner -> numericLiteral inner
  Number _ -> True
  DecimalNumber _ _ -> True
  Unary "-" inner -> numericLiteral inner
  _ -> False

-- Products keep the same literal context as a direct numeric argument. Explicit
-- annotations and computed values keep their own types.
contextualLiteralArgument :: Expr -> Bool
contextualLiteralArgument e = numericLiteral e || case e of
  Located _ inner -> contextualLiteralArgument inner
  ListLit _ -> True
  RecordLit _ -> True
  ConstructLit _ _ -> True
  _ -> False

-- | Calls are checked against the function's whole signature, so the result type
-- can type literal arguments.
application :: Expr -> (Expr,[Expr])
application (Located _ e) = application e
application (Apply f x) = let (n,args) = application f in (n,args ++ [x])
application e = (e,[])
-- | Checking against an expected type lets literals and constructors take their
-- type from context; a computed exact value bridges through a checked
-- conversion at run time. ref:DEC-portable-exact-arithmetic
checkExpr :: Env -> Type -> Expr -> C ()
checkExpr env expected (Located _ e) = checkExpr env expected e
checkExpr env expected e | Just (value,checks) <- selectionValidation e = do
  checkSelectionShapes env checks
  checkExpr env expected value
  checkSelectionBranches env expected checks
checkExpr env expected e = do
  t <- resolve (baseType expected)
  bits <- gets machineBits
  case (t,e) of
    (RecordShape declared,RecordLit fields) -> do
      checkRecordFields declared
      let labels = map fst fields
          expectedLabels = map recordFieldLabel declared
      unless (length labels == length (nub labels)) (throwC "duplicate record value field")
      unless (sort labels == sort expectedLabels) (throwC "record value must supply exactly its declared fields")
      let types = [(recordFieldLabel field,recordFieldType field) | field <- declared]
      sequence_ [maybe (throwC "unknown record value field") (\ty -> checkExpr env ty value) (lookup label types)
        | (label,value) <- fields]
    (Variable _,RecordLit _) -> infer env e >>= unify t
    (_,RecordLit _) -> throwC "an anonymous record literal requires a structural record type"
    (_,ConstructLit name fields) -> do
      parameters <- constructorParameters t name
      unless (length parameters == length fields) (throwC ("wrong constructor arity: " ++ name))
      zipWithM_ (checkExpr env) parameters fields
    (_,MatchExpr value branches) -> do
      scopes <- matchScopesWithResult env (Just t) value branches
      sequence_ [withGivens local (checkExpr scope t body) | (Just (scope, local), MatchBranch _ _ body) <- zip scopes branches]
    (Applied "List" element,ListLit xs) -> mapM_ (checkExpr env element) xs
    -- if c then a else b: each branch is checked against the expected type.
    (_,Apply _ _) | (Var "prelude.select", [c, a, b]) <- application e -> do
      checkExpr env (Named "Bool") c
      checkExpr env t a
      checkExpr env t b
    (Named n,Number x) | isNumeric n -> lift (convertScalar bits n (SInteger "BigInt" x)) >> pure ()
    (Named n,DecimalNumber c e) | isNumeric n -> lift (convertScalar bits n (SDecimal c e)) >> pure ()
    (Named n,ScalarLit v) | isExact n && isExact (scalarName v) -> lift (convertScalar bits n v) >> pure ()
    (Applied "Nullable" _,ScalarLit (SAbsent "Null")) -> pure ()
    (Applied "Optional" _,ScalarLit (SAbsent "Undefined")) -> pure ()
    (Applied n a,ScalarLit (SPresent m (Just v))) | n == m -> checkExpr env a (ScalarLit v)
    (Applied n _,ScalarLit (SPresent m Nothing)) | n == m -> pure ()
    (_,Apply _ _) | (Var name,args) <- application e, take 8 name /= "prelude.", any contextualLiteralArgument args ->
      checkApplication env t e >> pure ()
    _ -> do
      actual <- infer env e
      checkInferred t e actual

-- | Check the type already inferred for this occurrence. Re-inferring a universal
-- value here would create a different instantiation and lose its constraints.
checkInferred :: Type -> Expr -> Type -> C ()
checkInferred expected e inferred = do
  t <- resolve expected
  actual <- resolve inferred
  bits <- gets machineBits
  case (t,actual) of
    -- Reuse the existing typed conversion proof for exact scalar domains.
    -- Whole products and nominal types do not enter this rule. Floating
    -- conversions retain their explicit spelling, including possible rounding.
    (Named n,Named m) | isExact n && isExact m,
      safeConversionTypes bits (Core.scalarType n) (Core.scalarType m) Nothing -> pure ()
    (Named "Integer",Named m) | isInteger m -> pure ()
    -- Computed exact results use a checked adapter bridge at execution time.
    (Named n,Named m) | isExact n && m `elem` ["Integer","BigInt","Decimal","Rational"], not (isLiteral e) -> pure ()
    _ -> unify t actual
-- | Only literals take their type from context; computed values keep theirs.
isLiteral :: Expr -> Bool
isLiteral (Located _ e) = isLiteral e
isLiteral (Number _) = True
isLiteral (DecimalNumber _ _) = True
isLiteral (ScalarLit _) = True
isLiteral (StringLit _) = True
isLiteral (BoolLit _) = True
isLiteral (ListLit _) = True
isLiteral (ConstructLit _ _) = True
isLiteral (RecordLit _) = True
isLiteral _ = False

-- Successful unification already establishes corresponding stored field
-- types. Reordering source fields changes neither storage nor the native
-- representation, including when the product is nested in a container.
needsConversion :: Type -> Type -> Bool
needsConversion target source = not (same target source)
  where
    same a b | a == b = True
    same (RecordShape _) (RecordShape _) = True
    same (Applied n a) (Applied m b) = n == m && same a b
    same (Application n as) (Application m bs) = n == m && length as == length bs && and (zipWith same as bs)
    same (Arrow a b) (Arrow c d) = same a c && same b d
    same _ _ = False
-- | Each operand may type the other's literal, so 0.5 * x is Float32 when x is,
-- without a conversion the author did not write.
operandTypes :: Env -> Expr -> Expr -> C (Type,Type)
operandTypes env a b = do
  previousRequirements <- gets obligations
  initialA <- infer env a
  initialB <- infer env b
  (at,bt) <- if contextualStructure initialA a && contextualStructure initialB b
    then do
      context <- jointLiteralType env a b initialA initialB
      pure (context,context)
    else do
      left <- resolve initialA
      right <- resolve initialB
      let contextual t e fallback = case t of
            Named n | isInexact n && contextualNumber e -> checkExpr env t e >> pure t
            Application _ _ | isLiteral e || literalApplication e -> checkExpr env t e >> pure t
            RecordShape _ | isLiteral e || literalApplication e -> checkExpr env t e >> pure t
            Applied _ _ | isLiteral e || literalApplication e -> checkExpr env t e >> pure t
            _ -> pure fallback
      left' <- contextual right a left
      right' <- contextual left b right
      pure (left',right')
  provisional <- mapM resolve [initialA,initialB]
  selected <- mapM resolve [at,bt]
  -- A contextual instantiation replaces provisional defaults, not their
  -- capability requirements. Recheck both actual operands at the selected
  -- types; unrelated requirements and rigid substitutions remain intact.
  when (provisional /= selected && (hasLiteralApplication a || hasLiteralApplication b)) $ do
    modify (\state -> state{obligations=previousRequirements})
    checkExpr env at a
    checkExpr env bt b
  (,) <$> resolve at <*> resolve bt

literalApplication :: Expr -> Bool
literalApplication value = case application value of
  (Var name,args) -> take 8 name /= "prelude." && any contextualLiteralArgument args
  _ -> False

hasLiteralApplication :: Expr -> Bool
hasLiteralApplication value = literalApplication value || case unlocated value of
  ListLit items -> any hasLiteralApplication items
  RecordLit fields -> any (hasLiteralApplication . snd) fields
  ConstructLit _ fields -> any hasLiteralApplication fields
  _ -> False

contextualStructure :: Type -> Expr -> Bool
contextualStructure ty value = structuralLiteral value ||
  (case ty of Applied _ _ -> True; Application _ _ -> True; RecordShape _ -> True; _ -> False) && literalApplication value

-- Typed children share the enclosing equality's instantiation, including a
-- polymorphic builder whose argument is an empty collection.
operationOperandTypes :: Env -> String -> Expr -> Expr -> C (Type,Type)
operationOperandTypes env op a b = do
  (at,bt) <- operandTypes env a b
  let structural ty = case ty of
        Named name -> not (isNumeric name) && take 1 name /= "@"
        _ -> True
  if op `elem` ["==","!="] && at /= bt && structural at && structural bt
    then unify at bt >> ((,) <$> resolve at <*> resolve bt)
    else pure (at,bt)

-- A literal product may take its scalar field types from the other literal.
-- Failed alternatives restore inference state, including fresh variables and
-- capability obligations. Existing values still use ordinary unification.
jointLiteralType :: Env -> Expr -> Expr -> Type -> Type -> C Type
jointLiteralType env a b left right = do
  unified <- tryC (unify left right >> resolve left)
  case unified of
    Right context -> pure context
    Left original -> do
      contextual <- tryC (checkExpr env left a >> checkExpr env left b >> resolve left)
      case contextual of
        Right context -> pure context
        Left _ -> do
          other <- tryC (checkExpr env right a >> checkExpr env right b >> resolve right)
          either (const (throwC original)) pure other

-- | The prelude's built-in operations have types that ordinary signatures cannot
-- state, such as checked's, so they are typed here.
builtin :: Env -> String -> [Expr] -> C Type
builtin env n args
  | "prelude." ++ n == tuplePatternCheckName, [subject,count] <- args, Just arity <- patternArity count = do
      ty <- infer env subject >>= resolve
      case baseType ty of
        RecordShape fields | Just values <- positionalItems [(recordFieldLabel field,recordFieldType field) | field <- fields],
            toInteger (length values) == arity -> checkRecordFields fields
        _ -> throwC "a tuple pattern requires a structural tuple of the same arity"
      pure (Named "Bool")
  | "prelude." ++ n == recordPatternCheckName, [subject] <- args = do
      ty <- infer env subject >>= resolve
      case baseType ty of
        RecordShape fields -> checkRecordFields fields
        t -> do
          let parent = case t of Named name -> name; Applied name _ -> name; Application name _ -> name; _ -> ""
          known <- typesNamed parent
          case known of
            [declaration] | [constructor] <- Core.dataConstructors declaration,
                Core.constructorName constructor == Core.dataName declaration -> pure ()
            _ -> throwC "an empty record pattern requires a known record type"
      pure (Named "Bool")
  | n == "checked", [a] <- args = do
      t <- infer env a >>= resolve
      when (case t of Arrow _ _ -> True; _ -> False) (throwC "checked requires an evaluated scalar result, not a function")
      pure (Named "Bool")
  | n `elem` ["isPresent","presentValue"], [a] <- args = do
      t <- infer env a >>= resolve
      case t of Applied wrapper inner | wrapper `elem` ["Nullable","Optional"] -> pure (if n == "isPresent" then Named "Bool" else inner); _ -> throwC "presence helper requires Nullable or Optional"
  -- unreachable "C" stands for a branch the indices rule out: it takes any
  -- type, and the totality audit proves it is never reached.
  | n == "unreachable", [message] <- args = do
      checkExpr env (Named "Text") message
      Variable . ("unreachable:" ++) <$> fresh
  -- concurrently v is v: an all group's steps, evaluated at the same time.
  | n == "concurrently", [a] <- args = infer env a >>= resolve
  -- handle e with h end has e's value.
  | Just _ <- handledBy ("prelude." ++ n), [a] <- args = infer env a >>= resolve
  -- raise e is the Fail ability's operation: it aborts to the nearest
  -- handler of Fail, so it may stand for a value of any type.
  | n == "raise", [a] <- args = do
      _ <- infer env a
      Variable . ("raise:" ++) <$> fresh
  -- attempt e is Right e, or Left err when e raises err.
  | n == "attempt", [a] <- args = do
      t <- infer env a >>= resolve
      failure <- Variable . ("attempt:" ++) <$> fresh
      pure (Application "Either" [failure, t])
  -- calls of op [with (a, b)]: how many times a recording handler saw op.
  | n == "calls", (op : rest) <- args = do
      t <- infer env op >>= resolve
      let (parameters, _) = functionType t
      unless (null rest || length rest == length parameters)
        (throwC "calls of op with (...) needs one value for each of op's arguments")
      zipWithM_ (checkExpr env) parameters rest
      pure (Named "Int64")
  -- Membership compares elements; iteration itself has no Eq obligation.
  | n == "member", [value,collection] <- args = do
      (_,element) <- membershipTypes env value collection
      require "Eq" element
      pure (Named "Bool")
  -- Matchers (LawSpec.Matchers). xs contains x: an item of a List, or a
  -- Text inside a Text.
  | n == "contains", [a,b] <- args = do
      t <- infer env a >>= resolve
      case t of
        Named "Text" -> checkExpr env (Named "Text") b
        Applied "List" element -> checkExpr env element b >> require "Eq" element
        _ -> throwC ("contains needs a List or a Text, not " ++ prettyType t)
      pure (Named "Bool")
  | n `elem` ["startsWith","endsWith"], [a,b] <- args = do
      checkExpr env (Named "Text") a
      checkExpr env (Named "Text") b
      pure (Named "Bool")
  -- regexMatches pattern text: the pattern is a regex literal's text.
  | n == "regexMatches", [a,b] <- args = do
      checkExpr env (Named "Text") a
      checkExpr env (Named "Text") b
      pure (Named "Bool")
  -- within tolerance x y: numbers of one type at most tolerance apart.
  | n == "within", [tolerance,a,b] <- args = do
      (at, bt) <- operandTypes env a b
      t <- if at == bt then pure at else do
        unify at bt
        resolve at
      unless (case t of Named name -> isNumeric name && name `notElem` ["Complex64","Complex128"]; _ -> False)
        (throwC ("is within compares numbers, not " ++ prettyType t))
      checkExpr env t tolerance
      pure (Named "Bool")
  -- messageContains failure text: the failure's message field contains text.
  | n == "messageContains", [failure,text] <- args = do
      t <- infer env failure >>= resolve
      let parent = case t of Named name -> name; Applied name _ -> name; Application name _ -> name; _ -> ""
      known <- typesNamed parent
      withMessage <- forM [c | d <- known, c <- Core.dataConstructors d] $ \constructor -> do
        shape <- matchConstructor t (Core.idText (Core.constructorId constructor))
        case shape of
          Just (fields,_) -> do
            let named = zip (map Core.binderName (Core.constructorFields constructor)) fields
            if any (\(name,ty) -> name == "message" && baseType ty == Named "Text") named
              then pure True else case named of
                [("value",payload)] -> do
                  -- Canonical alternatives have one explicit payload. A
                  -- documentary message belongs to its record, not to an
                  -- arbitrary Text value or an implicitly unwrapped nominal.
                  let local = "lawspecFailureMessagePayload"
                  field <- tryC (fieldType (monoEnvironment [(local,payload)])
                    (Apply (Var (fieldAccessPrefix ++ "message")) (Var local)) >>= resolve)
                  pure (case field of Right ty -> baseType ty == Named "Text"; Left _ -> False)
                _ -> pure False
          Nothing -> pure False
      unless (or withMessage) (throwC ("message contains needs a failure type with a Text message field; " ++ prettyType t ++ " has none"))
      checkExpr env (Named "Text") text
      pure (Named "Bool")
  -- recorded name value: value's rendering equals the recording's.
  | n == "recorded", [name,value] <- args = do
      checkExpr env (Named "Text") name
      _ <- infer env value
      pure (Named "Bool")
  -- select c a b is a when c holds and b otherwise; both are values.
  | n == "select", [c,a,b] <- args = do
      checkExpr env (Named "Bool") c
      -- A numeric literal branch takes the other branch's type.
      let (first, second) = if numericLiteral a && not (numericLiteral b) then (b, a) else (a, b)
      t <- infer env first >>= resolve
      checkExpr env t second
      pure t
  -- The portable total order, as the collections unit's Ordering.
  | n == "compare", [a,b] <- args = do
      t <- infer env a >>= resolve
      checkExpr env t b
      require "Keyed" t
      pure (Named (collectionsUnit ++ "::type::Ordering"))
  -- A collection's items, count and emptiness; a KeyVal's items are its
  -- entries.
  | n `elem` ["toList","size","isEmpty"], [a] <- args = do
      t <- infer env a >>= resolve
      items <- case t of
        Applied c e | Just short <- collectionName c, short `elem` ["Set","EqSet","Queue","Stack","Deque"] -> pure e
        Application c [k,v] | collectionName c == Just "KeyVal" -> pure (Application (collectionsUnit ++ "::type::Entry") [k,v])
        Applied "List" e -> pure e
        _ -> throwC ("prelude." ++ n ++ " requires a List, Set, KeyVal, Queue, Stack or Deque")
      pure (case n of "toList" -> Applied "List" items; "size" -> Named "Integer"; _ -> Named "Bool")
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
  -- Arithmetic into a bounded integer type, taken from the context:
  -- prelude.wrapping (n + 1) wraps around it, prelude.saturating stops at
  -- its bounds, and prelude.bounded gives Nothing outside them.
  | n `elem` ["wrapping","saturating","bounded"], [a] <- args = do
      t <- infer env a >>= resolve
      unless (case t of Named name -> isInteger name; _ -> False)
        (throwC ("prelude." ++ n ++ " takes an integer, not " ++ prettyType t))
      result <- Variable . (("bounded:" ++ n) ++) <$> fresh
      pure (if n == "bounded" then Applied "Maybe" result else result)
  -- Sequences: Text, Bytes and List (LawSpec.Core's Append ... Join).
  | n == "append", [a,b] <- args = do
      t <- infer env a >>= resolve
      sequenceOnly n t
      checkExpr env t b
      resolve t
  | n == "slice", [from,to,x] <- args = do
      t <- infer env x >>= resolve
      sequenceOnly n t
      checkExpr env (Named "Integer") from
      checkExpr env (Named "Integer") to
      pure t
  | n `elem` ["take","drop"], [k,x] <- args = do
      t <- infer env x >>= resolve
      sequenceOnly n t
      checkExpr env (Named "Integer") k
      pure t
  | n == "at", [i,x] <- args = do
      t <- infer env x >>= resolve
      checkExpr env (Named "Integer") i
      case t of
        Applied "List" element -> pure (Applied "Maybe" element)
        Named "Bytes" -> pure (Applied "Maybe" (Named "UInt8"))
        _ -> throwC ("prelude.at needs a List or Bytes, not " ++ prettyType t)
  | n == "range", [lo,hi] <- args = do
      -- The integers from lo up to, not including, hi, of their type.
      let (first, second) = if numericLiteral lo && not (numericLiteral hi) then (hi, lo) else (lo, hi)
      t <- infer env first >>= resolve
      checkExpr env t second
      unless (case t of Named name -> isInteger name; _ -> False)
        (throwC ("prelude.range counts integers, not " ++ prettyType t))
      pure (Applied "List" t)
  | n == "octets", [b] <- args = checkExpr env (Named "Bytes") b >> pure (Applied "List" (Named "UInt8"))
  | n == "bytesOf", [xs] <- args = checkExpr env (Applied "List" (Named "UInt8")) xs >> pure (Named "Bytes")
  | n == "utf8", [t] <- args = checkExpr env (Named "Text") t >> pure (Named "Bytes")
  | n == "textOf", [x] <- args = do
      t <- infer env x >>= resolve
      unless (case t of Named name -> isInteger name; _ -> False)
        (throwC ("prelude.textOf writes an integer, not " ++ prettyType t))
      pure (Named "Text")
  | n == "join", [sep,parts] <- args = do
      checkExpr env (Named "Text") sep
      checkExpr env (Applied "List" (Named "Text")) parts
      pure (Named "Text")
  | otherwise = throwC ("unknown helper or wrong arity: prelude." ++ n)
  where
    patternArity value = case unlocated value of
      Number n -> Just n
      ScalarLit (SInteger _ n) -> Just n
      Annotate inner _ -> patternArity inner
      _ -> Nothing
    sequenceOnly name t = unless (t `elem` [Named "Text", Named "Bytes"] || case t of Applied "List" _ -> True; _ -> False)
      (throwC ("prelude." ++ name ++ " needs a Text, Bytes or List, not " ++ prettyType t))
-- | The IR resolves every operation and the expected type of every adapter argument.
typedExpression :: Int -> [(String,Type)] -> Expr -> Either String TypedExpr
typedExpression = typedExpressionWithData []

-- | User data types are known when typing an expression that constructs them.
typedExpressionWithData :: [Core.DataDeclaration] -> Int -> [(String,Type)] -> Expr -> Either String TypedExpr
typedExpressionWithData = typedExpressionWithContext Source.emptyContext

typedExpressionWithContext :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> [(String,Type)] -> Expr -> Either String TypedExpr
typedExpressionWithContext context declarations bits env expression =
  fst <$> typedExpressionWithSchemesContext context declarations bits (monoEnvironment env) expression

-- | Elaboration needs both the typed tree and the capabilities it requires, so
-- the obligations are returned rather than discharged here.
typedExpressionWithSchemes :: [Core.DataDeclaration] -> Int -> Env -> Expr -> Either String (TypedExpr, [Constraint])
typedExpressionWithSchemes = typedExpressionWithSchemesContext Source.emptyContext

typedExpressionWithSchemesContext :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> Env -> Expr -> Either String (TypedExpr,[Constraint])
typedExpressionWithSchemesContext context declarations bits env e = do
  _ <- makeRegistry declarations
  evalStateT (do
    expression <- go env Nothing e >>= resolveTree
    requirements <- gets obligations >>= mapM (\(Capability name ty) -> Capability name <$> resolve ty)
    pure (expression, nub requirements)) (withSourceContext context (withDataDeclarations declarations (initialState bits)))
  where
    go context expected (Located range e) = do
      value <- go context expected e
      pure value{expression=Located range (expression value)}
    go context expected e | Just (value,checks) <- selectionValidation e = do
      checkSelectionShapes context checks
      made <- go context expected value
      checkSelectionBranches context (maybe (expressionType made) id expected) checks
      pure made
    go context expected e | isFieldNode e = do
      direct <- fieldAccessTyped context expected e
      maybe (fieldDesugar context e >>= go context expected) pure direct
    go context expected e = do
      let descend = go context
      natural <- case (expected, e) of
        (Just targetType, RecordLit _) -> checkExpr context targetType e >> resolve targetType
        (Just targetType, ConstructLit _ _) -> checkExpr context targetType e >> resolve targetType
        (Just targetType, MatchExpr _ _) -> checkExpr context targetType e >> resolve targetType
        -- Each branch of if c then a else b takes the expected type, so each
        -- converts on its own, as a match's branches do.
        (Just targetType, Apply _ _) | (Var "prelude.select", [c, a, b]) <- application e -> do
          checkExpr context (Named "Bool") c
          checkExpr context targetType a
          checkExpr context targetType b
          resolve targetType
        (Just targetType, ListLit _) -> checkExpr context targetType e >> resolve targetType
        (Just targetType,MatchExpr _ [MatchBranch tag [_] _]) | tag == letTag ->
          checkExpr context targetType e >> resolve targetType
        -- An application checks against its expected type before its
        -- numeric literals, which may then take a polymorphic parameter's
        -- type from it.
        (Just targetType, Apply _ _) | (Var n, args) <- application e, take 8 n /= "prelude.", any contextualLiteralArgument args ->
          checkApplication context targetType e
        _ -> do
          inferred <- infer context e
          case expected of
            Just targetType | isLiteral e -> checkExpr context targetType e
                            | otherwise -> checkInferred targetType e inferred
            Nothing -> pure ()
          resolve inferred
      t <- resolve (if isLiteral e then maybe natural id expected else natural)
      target <- traverse resolve expected
      let conversion = case target of Just targetType | needsConversion targetType t -> Just targetType; _ -> Nothing
      children <- case e of
        RecordLit fields -> case t of
          RecordShape declared -> sequence [case [recordFieldType field | field <- declared,recordFieldLabel field == label] of
            [ty] -> descend (Just ty) value
            _ -> throwC "unknown record value field" | (label,value) <- fields]
          _ -> throwC "record literal requires a structural record type"
        AllPayloadsExpr value _ -> sequence [descend Nothing value]
        AllElementsExpr value binder predicate -> do
          (collection,_) <- iterationTypes context value binder predicate
          sequence [descend (Just collection) value]
        MatchExpr value branches@[MatchBranch tag [name] _] | tag == letTag -> do
          scopes <- matchScopesWithResult context (Just t) value branches
          case scopes of
            [Just (scope,_)] -> case M.lookup name scope of
              Just scheme -> sequence [descend (Just (schemeType scheme)) value]
              Nothing -> throwC "missing typed let binding"
            _ -> throwC "invalid typed let scope"
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
        -- Both of select's values take its type, as a match's branches do.
        Apply _ _ | (Var "prelude.select", [c,a,b]) <- application e ->
          sequence [descend (Just (Named "Bool")) c, descend (Just t) a, descend (Just t) b]
        -- A matcher's literals take the type of what they are compared with.
        Apply _ _ | (Var "prelude.within", [tolerance,a,b]) <- application e -> do
          (at,bt) <- operandTypes context a b
          number <- resolve at
          sequence [descend (Just number) tolerance, descend (Just at) a, descend (Just bt) b]
        Apply _ _ | (Var "prelude.member", [value,collection]) <- application e -> do
          (collectionType,element) <- membershipTypes context value collection
          sequence [descend (Just element) value, descend (Just collectionType) collection]
        Apply _ _ | (Var "prelude.contains", [whole,part]) <- application e -> do
          wholeType <- infer context whole >>= resolve
          case wholeType of
            Applied "List" element -> sequence [descend (Just wholeType) whole, descend (Just element) part]
            _ -> mapM (descend Nothing) [whole, part]
        -- A sequence helper's indices are Integers, and range's bounds and
        -- append's sides have the result's type.
        Apply _ _ | (Var n,args) <- application e, n `elem` ["prelude.slice","prelude.take","prelude.drop","prelude.at"] ->
          sequence [descend (if i < length args - 1 then Just (Named "Integer") else Nothing) a | (i, a) <- zip [0 :: Int ..] args]
        Apply _ _ | (Var "prelude.range", [lo,hi]) <- application e, Applied "List" element <- t ->
          sequence [descend (Just element) lo, descend (Just element) hi]
        Apply _ _ | (Var "prelude.append", [a,b]) <- application e -> sequence [descend (Just t) a, descend (Just t) b]
        Apply _ _ | (Var n,args) <- application e, Just expected' <- lookup n fixedSignatures, length expected' == length args ->
          sequence [descend (Just ty) a | (ty, a) <- zip expected' args]
        Apply _ _ | (Var n,args) <- application e, take 8 n == "prelude." -> mapM (descend Nothing) args
        -- With a numeric literal among its arguments, the function's
        -- expected type carries the argument's and the result's, so a
        -- partial application's literals see both.
        Apply f x | any contextualLiteralArgument (snd (application e)) -> do
          -- The declared function parameter supplies the expected argument
          -- type. Inferring a computed exact argument first would force its
          -- natural type and lose the existing checked scalar conversion.
          argument <- Variable . ("argument:" ++) <$> fresh
          function <- resolve (Arrow argument natural)
          f' <- descend (Just function) f
          a <- resolve argument
          x' <- descend (Just a) x
          pure [f', x']
        Apply f x -> do
          ft <- infer context f >>= resolve
          case ft of
            Arrow a b -> do
              unify b natural
              checkExpr context a x
              function <- resolve ft
              sequence [descend (Just function) f,descend (Just a) x]
            _ -> sequence [descend Nothing f,descend Nothing x]
        Binary op a b -> do (at,bt) <- operationOperandTypes context op a b; sequence [descend (Just at) a,descend (Just bt) b]
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
          (_,element) <- iterationTypes context value binder predicate
          body <- go (M.insert binder (Monomorphic element) context) (Just (Named "Bool")) predicate
          pure [TypedCase "" [(binder,element)] body]
        -- A let binds this occurrence's inferred value. Inferring it again
        -- would give a polymorphic constructor such as Nothing a different
        -- type variable, losing the body context that fixes its payload type.
        MatchExpr _ [MatchBranch tag [name] body] | tag == letTag, [value] <- children -> do
          let boundType = maybe (expressionType value) id (requiredConversion value)
          body' <- go (M.insert name (Monomorphic boundType) context) (Just t) body
          resolved <- resolve boundType
          pure [TypedCase tag [(name,resolved)] body']
        -- Branches a GADT constructor cannot reach at this type are dropped,
        -- so a specialized instance never mentions them.
        MatchExpr value branches -> do
          scopes <- matchScopes context value branches
          concat <$> sequence [withGivens local $ if tag == "_"
            then do
              body' <- go scope (Just t) body
              valueType <- infer context value >>= resolve
              others <- matchWildcard valueType [other | MatchBranch other _ _ <- branches]
              pure [TypedCase constructor (zip ["lawspecOther" ++ show i | i <- [0 :: Int ..]] fields) body' | (constructor, fields) <- others]
            else do
              types <- mapM (\name -> maybe (throwC "missing pattern binder") (resolve . schemeType) (M.lookup name scope)) names
              body' <- go scope (Just t) body
              pure [TypedCase tag (zip names types) body']
            | (Just (scope, local), MatchBranch tag names body) <- zip scopes branches]
        _ -> pure []
      pure (TypedExpr t e' children conversion cases)
    -- b.f typed directly, as the field it reads, and b with f = v as the
    -- value with one field replaced: the typed tree keeps the field node, so
    -- neither visits every field of the record, at each access
    -- (LawSpec.Elaboration makes it a projection, or the match it stands
    -- for).
    fieldAccessTyped context expected e = case application e of
      (Var n, [subject]) | Just field <- stripPrefix fieldAccessPrefix n -> do
        (t, shape, names) <- fieldShape context subject field
        case shape of
          Nothing -> pure Nothing
          Just fields -> do
            subjectType <- resolve t
            subject' <- go context (Just subjectType) subject
            let index = length (takeWhile (/= field) names)
            fieldType' <- resolve (fields !! index)
            target <- traverse resolve expected
            forM_ target $ \targetType -> checkInferred targetType e fieldType'
            target' <- traverse resolve target
            fieldType'' <- resolve fieldType'
            let conversion = case target' of
                  Just targetType | needsConversion targetType fieldType'' -> Just targetType
                  _ -> Nothing
            pure (Just (TypedExpr fieldType'' e [subject'] conversion []))
      (Var n, [subject, value]) | Just field <- stripPrefix fieldUpdatePrefix n -> do
        (t, shape, names) <- fieldShape context subject field
        case shape of
          Nothing -> pure Nothing
          Just fields -> do
            subjectType <- resolve t
            let index = length (takeWhile (/= field) names)
            fieldType' <- resolve (fields !! index)
            value' <- go context (Just fieldType') value
            subject' <- go context (Just subjectType) subject
            target <- traverse resolve expected
            forM_ target $ \targetType -> checkInferred targetType e subjectType
            target' <- traverse resolve target
            subjectType' <- resolve subjectType
            let conversion = case target' of
                  Just targetType | needsConversion targetType subjectType' -> Just targetType
                  _ -> Nothing
            pure (Just (TypedExpr subjectType' e [subject', value'] conversion []))
      _ -> pure Nothing
    resolveTree (TypedExpr ty expression operands conversion cases) = do
      ty' <- resolve ty
      operands' <- mapM resolveTree operands
      conversion' <- traverse resolve conversion
      cases' <- mapM (\(TypedCase tag fields body) -> do
        fields' <- mapM (\(name, field) -> (,) name <$> resolve field) fields
        TypedCase tag fields' <$> resolveTree body) cases
      pure (TypedExpr ty' expression operands' conversion' cases')

-- | The prelude helpers whose values have one type each.
fixedSignatures :: [(String, [Type])]
fixedSignatures =
  [ ("prelude.octets", [Named "Bytes"]), ("prelude.bytesOf", [Applied "List" (Named "UInt8")])
  , ("prelude.utf8", [Named "Text"]), ("prelude.join", [Named "Text", Applied "List" (Named "Text")]) ]

-- | Whether an expression reads or replaces a field (see fieldAccessPrefix).
isFieldNode :: Expr -> Bool
isFieldNode e = case application e of
  (Var n, [_]) -> fieldAccessPrefix `isPrefixOf` n
  (Var n, [_, _]) -> fieldUpdatePrefix `isPrefixOf` n
  _ -> False

-- | b.f is a match on the single constructor of b's type that gives the
-- field f; b with f = v is one that builds the value again with v in f's
-- place. The value is evaluated before the match, so the match's binders
-- never capture its names. ref:DEC-field-access-desugars-to-match
fieldDesugar :: Env -> Expr -> C Expr
fieldDesugar env e = case application e of
  (Var n, [subject]) | Just field <- stripPrefix fieldAccessPrefix n -> do
    (constructor, names) <- constructorOf subject field
    tag <- fresh
    let binders = ["lawspecField" ++ tag ++ "x" ++ show i | i <- [0 .. length names - 1]]
    pure (MatchExpr subject [MatchBranch constructor binders (Var (binders !! index field names))])
  (Var n, [subject, value]) | Just field <- stripPrefix fieldUpdatePrefix n -> do
    (constructor, names) <- constructorOf subject field
    subjectType <- infer env subject >>= resolve
    tag <- fresh
    let binders = ["lawspecField" ++ tag ++ "x" ++ show i | i <- [0 .. length names - 1]]
        -- The copy has the value's type, which a literal field needs when
        -- the type is generic, as Box Int32's item 0 is an Int32.
        ground t = case t of
          Variable _ -> False
          Named n -> take 1 n /= "@"
          Arrow a b -> ground a && ground b
          Applied _ a -> ground a
          Application _ as -> all ground as
          _ -> False
        typed c = if ground subjectType then Annotate c subjectType else c
        replacement = "lawspecUpdate" ++ tag
        -- A literal or a name is placed as it is, so a literal takes the
        -- field's type; anything else is evaluated first.
        simple = isLiteral value || case unlocated value of Var _ -> True; _ -> False
        new = if simple then value else Var replacement
        fields = [if i == index field names then new else Var b | (i, b) <- zip [0 ..] binders]
        rebuilt = MatchExpr subject [MatchBranch constructor binders (typed (ConstructLit constructor fields))]
    pure (if simple then rebuilt else MatchExpr value [MatchBranch letTag [replacement] rebuilt])
  _ -> throwC "invalid field access"
  where
    index field names = length (takeWhile (/= field) names)
    constructorOf subject field = do
      t <- infer env subject >>= resolve
      let parent = case t of Named name -> name; Applied name _ -> name; Application name _ -> name; _ -> ""
          what = "." ++ field ++ ": "
      when (null parent || take 1 parent == "@") (throwC (what ++ "the type of the value must be known here; annotate it"))
      when (isCollectionsName parent) (throwC (what ++ prettyType t ++ " has no fields; use its prelude operations"))
      known <- typesNamed parent
      case known of
        [d] -> case Core.dataConstructors d of
          [c] -> do
            let names = map Core.binderName (Core.constructorFields c)
            unless (field `elem` names) (throwC (what ++ prettyType t ++ " has no field called " ++ field ++
              (if null names then "" else "; its fields are " ++ intercalate ", " names)))
            pure (Core.idText (Core.constructorId c), names)
          _ -> throwC (what ++ prettyType t ++ " has more than one constructor, so a field is read with match")
        _ -> throwC (what ++ prettyType t ++ " is not a data type with fields")
    isCollectionsName parent = (collectionsUnit ++ "::type::") `isPrefixOf` parent &&
      drop (length collectionsUnit + 8) parent `elem` ["Set", "EqSet", "KeyVal", "Queue", "Stack", "Deque"]

-- | The type of b.f or b with f = v, without building the match it
-- desugars to: inferring that match again at every enclosing expression,
-- with a binder for every field, made checking a model over a record of
-- hundreds of fields quadratic. A GADT constructor is desugared.
fieldType :: Env -> Expr -> C Type
fieldType env e = case application e of
  (Var n, [subject]) | Just field <- stripPrefix fieldAccessPrefix n -> do
    (t, shape, names) <- fieldShape env subject field
    case shape of
      Just fields -> pure (fields !! length (takeWhile (/= field) names))
      Nothing -> fieldDesugar env e >>= infer env
  (Var n, [subject, value]) | Just field <- stripPrefix fieldUpdatePrefix n -> do
    (t, shape, names) <- fieldShape env subject field
    case shape of
      Just fields -> do
        checkExpr env (fields !! length (takeWhile (/= field) names)) value
        resolve t
      Nothing -> fieldDesugar env e >>= infer env
  _ -> fieldDesugar env e >>= infer env
-- | Field shape shared by inference and the typed expression builder. Structural
-- records keep their source shape; nominal GADTs retain constructor-local facts.
fieldShape :: Env -> Expr -> String -> C (Type,Maybe [Type],[String])
fieldShape env subject field = do
  ty <- infer env subject >>= resolve
  case ty of
    RecordShape fields -> do
      checkRecordFields fields
      let names = map recordFieldLabel fields
      unless (field `elem` names) (throwC ("." ++ field ++ ": record has no field called " ++ field))
      pure (ty,Just (map (baseType . recordFieldType) fields),names)
    _ -> do
      (t, constructor, names) <- fieldConstructor env subject field
      pairs <- gets (M.findWithDefault [] constructor . constructorsByName)
      shape <- shapeOf constructor pairs
      if not (null (shapeExistentials shape)) || any snd (shapeArguments shape)
        then pure (t, Nothing, names)
        else do
          unify (shapeResult shape) t
          fields <- mapM resolve (shapeFields shape)
          pure (t, Just fields, names)

-- | The single constructor of b's type, and its field names, for b.f.
fieldConstructor :: Env -> Expr -> String -> C (Type, String, [String])
fieldConstructor env subject field = do
  t <- infer env subject >>= resolve
  let parent = case t of Named name -> name; Applied name _ -> name; Application name _ -> name; _ -> ""
      what = "." ++ field ++ ": "
  when (null parent || take 1 parent == "@") (throwC (what ++ "the type of the value must be known here; annotate it"))
  when (isCollectionsName parent) (throwC (what ++ prettyType t ++ " has no fields; use its prelude operations"))
  known <- typesNamed parent
  case known of
    [d] -> case Core.dataConstructors d of
      [c] -> do
        let names = map Core.binderName (Core.constructorFields c)
        unless (field `elem` names) (throwC (what ++ prettyType t ++ " has no field called " ++ field ++
          (if null names then "" else "; its fields are " ++ intercalate ", " names)))
        pure (t, Core.idText (Core.constructorId c), names)
      _ -> throwC (what ++ prettyType t ++ " has more than one constructor, so a field is read with match")
    _ -> throwC (what ++ prettyType t ++ " is not a data type with fields")
  where
    isCollectionsName parent = (collectionsUnit ++ "::type::") `isPrefixOf` parent &&
      drop (length collectionsUnit + 8) parent `elem` ["Set", "EqSet", "KeyVal", "Queue", "Stack", "Deque"]

-- | Capabilities such as Eq a are collected as obligations and discharged once
-- every type is known.
require :: String -> Type -> C ()
require n t = modify (\s -> s{obligations=Capability n t:obligations s})

-- | Composition is turned into application before typing, so f . g and f (g x)
-- are checked and emitted alike.
normal :: Expr -> Expr
normal (Located range e) = Located range (normal e)
normal (ConstructLit name fields) = ConstructLit name (map normal fields)
normal (RecordLit fields) = RecordLit [(label,normal value) | (label,value) <- fields]
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


-- | Comparisons take two operands of one type and yield Bool.
comparison :: String -> Bool
comparison op = op `elem` ["<","<=",">",">=","==","!="]

-- | A floating context may type a numeric literal written without a fraction.
contextualNumber :: Expr -> Bool
contextualNumber (Located _ e) = contextualNumber e
contextualNumber (Number _) = True
contextualNumber (DecimalNumber _ _) = True
contextualNumber _ = False


-- | Instantiate constructor parameters freshly on every use. Shapes come from the
-- same built-in declarations that Core validates and the evaluator consumes.
constructorSignature :: String -> C ([Type], Type)
constructorSignature name = do
  pairs <- gets (M.findWithDefault [] name . constructorsByName)
  shape <- shapeOf name pairs
  realizeConstructor shape
  (,) <$> mapM resolve (shapeFields shape) <*> resolve (shapeResult shape)

-- | Most uses need only a constructor's fields and result.
instantiateConstructor :: String -> [Core.DataDeclaration] -> C ([Type], Type)
instantiateConstructor name declarations = do
  shape <- instantiateShape name declarations
  realizeConstructor shape
  (,) <$> mapM resolve (shapeFields shape) <*> resolve (shapeResult shape)

-- | A fresh instance of a constructor: its fields and result over fresh
-- variables for the declaration's parameters and the constructor's
-- existentials. A GADT constructor's result applies its equations.
data ConstructorShape = ConstructorShape
  { shapeFields :: [Type], shapeResult :: Type
  , shapeParameters :: [Type] -- the same fresh indices used in payload fields
  , shapeArguments :: [(Type, Bool)]  -- each result argument, and whether an equation fixed it
  , shapeExistentials :: [String]
  -- Existentials no refinement mentions: only a value says what they are.
  , shapeFieldOnly :: [String] }

-- | Constructors are read from the same declarations Core validates, so
-- inference and Core cannot disagree about a constructor's shape.
-- ref:DEC-typed-core-boundary
instantiateShape :: String -> [Core.DataDeclaration] -> C ConstructorShape
instantiateShape name declarations = shapeOf name
  [(declaration, constructor) | declaration <- declarations,
    constructor <- Core.dataConstructors declaration,
    Core.constructorName constructor == name || Core.idText (Core.constructorId constructor) == name]

-- | A fresh instance of the one constructor of these candidates.
shapeOf :: String -> [(Core.DataDeclaration, Core.DataConstructor)] -> C ConstructorShape
shapeOf name candidates = case candidates of
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
    catalogue <- gets (Source.constructorSources . sourceContext)
    source <- case M.lookup (Core.constructorId constructor) catalogue of
      Nothing -> pure Nothing
      Just original -> Just <$> lift (Source.instantiateSource variables original)
    equations <- case source of
      Just (_,equations) -> pure equations
      Nothing -> mapM (\(parameter, ty) -> (,) parameter <$> convert ty) (Core.constructorEquations constructor)
    let arguments = [maybe (variable, False) (\ty -> (ty, True)) (lookup parameter equations) | (parameter, variable) <- parameters]
        result = applyType (Core.idText (Core.dataId declaration)) (map fst arguments)
    fields <- case source of
      Just (fields,_) -> pure (map baseType fields)
      Nothing -> mapM (convert . Core.binderType) (Core.constructorFields constructor)
    let mentioned = concatMap (coreVariables . snd) (Core.constructorEquations constructor)
        fieldOnly = [v | (e, v) <- existentials, e `notElem` mentioned]
    pure (ConstructorShape fields result (map snd parameters) arguments (map snd existentials) fieldOnly)
  [] -> throwC ("unknown constructor: " ++ name)
  _ -> throwC ("ambiguous constructor: " ++ name)
  where
    applyType name [] = Named name
    applyType name [argument] = Applied name argument
    applyType name arguments = Application name arguments

-- Construction must satisfy the declared index equations in its fields as
-- well as its result. Matching solves these relations only inside the branch,
-- after testing accessibility and learning the scrutinee's rigid equations.
realizeConstructor :: ConstructorShape -> C ()
realizeConstructor shape = zipWithM_ unify (shapeParameters shape) (map fst (shapeArguments shape))

-- | An existential that no equation mentions is fixed only by a value.
coreVariables :: Core.Type -> [Core.Id]
coreVariables ty = case ty of
  Core.TypeVariable v -> [v]
  Core.Constructor _ arguments -> concat [coreVariables t | Core.TypeArgument t <- arguments]
  Core.Arrow a b -> coreVariables a ++ coreVariables b

-- | Facts learned in a GADT branch hold only in that branch.
-- ref:DEC-gadts-and-index-arithmetic
withGivens :: M.Map String Type -> C a -> C a
withGivens local action
  | M.null local = action
  | otherwise = do
      saved <- gets givens
      modify (\s -> s{givens = M.union local saved})
      result <- action
      modify (\s -> s{givens = saved})
      pure result

-- | Some checks try one reading and fall back to another without keeping the
-- failed attempt's substitutions.
tryC :: C a -> C (Either String a)
tryC action = StateT $ \s -> case runStateT action s of
  Left message -> Right (Left message, s)
  Right (value, s') -> Right (Right value, s')

-- | Matching a constructor against a scrutinee type: Nothing when the
-- constructor cannot build that type (the branch is inaccessible); otherwise
-- its field types and the givens its equations add for rigid variables.
-- Existentials the scrutinee does not determine become rigid in the branch.
matchConstructor :: Type -> String -> C (Maybe ([Type], M.Map String Type))
matchConstructor scrutinee tag = do
  resolved <- resolve scrutinee
  let (parent, arguments) = case resolved of
        Named n -> (n, []); Applied n a -> (n, [a]); Application n as -> (n, as); _ -> ("", [])
  candidates <- typesNamed parent
  shape <- if null candidates then gets (M.findWithDefault [] tag . constructorsByName) >>= shapeOf tag
    else instantiateShape tag candidates
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
    -- A fixed result argument otherwise leaves the constructor's original
    -- fresh parameter unbound in its payload. Tie those fields to the actual
    -- scrutinee indices under the branch's givens, including dependent index
    -- equations that share a determined existential.
    zipWithM_ unify (shapeParameters shape) arguments
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

-- | Unify a constructor's refinement with the scrutinee's argument; a rigid
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
    (RecordShape fields,RecordShape others) -> sameRecordIndices a b >> unifyRecordFields fields others >> pure M.empty
    _ -> throwC ("type mismatch: " ++ prettyType a ++ " and " ++ prettyType b)
  where
    refinable n = take 7 n /= "exists:"
    given :: String -> Type -> C (M.Map String Type)
    given n t = do
      modify (\s -> s{givens = M.insert n t (givens s)})
      pure (M.singleton n t)

-- | The constructor's variables are bound to the caller's types, not the
-- reverse, so Core binders keep the declared parameter identities.
constructorParameters :: Type -> String -> C [Type]
constructorParameters target name = do
  resolved <- resolve target
  let parent = case resolved of Named n -> Just n; Applied n _ -> Just n; Application n _ -> Just n; _ -> Nothing
  shape <- case parent of
    Just n -> typesNamed n >>= instantiateShape name
    Nothing -> gets (M.findWithDefault [] name . constructorsByName) >>= shapeOf name
  let (parameters, result) = (shapeFields shape, shapeResult shape)
  realizeConstructor shape
  -- Bind fresh constructor variables to the caller's parameters, not the
  -- reverse: Core binders retain those declared parameter identities.
  unify result target
  mapM resolve parameters

-- | Opposite sum constructors supply complementary type information. Infer both
-- in one substitution scope before assigning contextual types to either term.
structuralLiteral :: Expr -> Bool
structuralLiteral expression = case unlocated expression of
  ConstructLit _ _ -> True
  RecordLit _ -> True
  ListLit _ -> True
  _ -> False

-- | Opposite sum constructors, such as Left 1 and Right "a", each supply half of
-- the type, so both are inferred in one scope before either is annotated.
jointStructuralContext :: Env -> Expr -> Expr -> C (Expr, Expr)
jointStructuralContext env a b
  | structuralLiteral a && structuralLiteral b = do
      left <- infer env a
      right <- infer env b
      context <- jointLiteralType env a b left right
      pure (Annotate a context, Annotate b context)
  | literalApplication a || literalApplication b = do
      left <- infer env a >>= resolve
      right <- infer env b >>= resolve
      let structured ty = case ty of Applied _ _ -> True; Application _ _ -> True; RecordShape _ -> True; _ -> False
      if structured left && structured right then do
        (left',right') <- operationOperandTypes env "==" a b
        pure (Annotate a left',Annotate b right')
      else pure (a,b)
  | otherwise = pure (a,b)

-- | As jointStructuralContext, for callers outside inference.
contextualizeStructural :: Int -> [(String,Type)] -> Expr -> Expr -> Either String (Expr, Expr)
contextualizeStructural = contextualizeStructuralWithData []

-- | As contextualizeStructural, knowing the user's data types.
contextualizeStructuralWithData :: [Core.DataDeclaration] -> Int -> [(String,Type)] -> Expr -> Expr -> Either String (Expr, Expr)
contextualizeStructuralWithData = contextualizeStructuralWithContext Source.emptyContext

contextualizeStructuralWithContext :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> [(String,Type)] -> Expr -> Expr -> Either String (Expr,Expr)
contextualizeStructuralWithContext context declarations bits env a b =
  evalStateT (jointStructuralContext (monoEnvironment env) a b)
    (withSourceContext context (withDataDeclarations declarations (initialState bits)))

-- | Constructor coverage is checked while resolving branch environments and is
-- checked again independently at the Core boundary. Each branch is Nothing when
-- its GADT constructor cannot build the scrutinee's type, or its scope and the
-- givens it adds.
matchScopes :: Env -> Expr -> [MatchBranch] -> C [Maybe (Env, M.Map String Type)]
matchScopes env value branches = matchScopesWithResult env Nothing value branches

-- Constructor construction uses strict lets to retain source evaluation order.
-- A literal bound to one of its fields still takes that field's contextual
-- type. Find the direct constructor use through its lexical let chain without
-- evaluating or re-inferring the body. Fresh constructor parameters prevent an
-- authored type parameter with the same spelling from being captured.
constructorFieldContext :: String -> Maybe Type -> Expr -> C (Maybe Type)
constructorFieldContext name result expression = case unlocated expression of
  Annotate body ty -> constructorFieldContext name (Just ty) body
  MatchExpr _ [MatchBranch tag [binder] body] | tag == letTag,binder /= name -> constructorFieldContext name result body
  ConstructLit constructor fields -> case [index | (index,field) <- zip [0..] fields,unlocated field == Var name] of
    [] -> pure Nothing
    index:_ -> do
      types <- case result of
        Just ty -> constructorParameters ty constructor
        Nothing -> fst <$> constructorSignature constructor
      pure (case drop index types of ty:_ -> Just ty; [] -> Nothing)
  _ -> pure Nothing

-- Strict captures introduced for any retain the original function argument's
-- literal context. This is not general let-polymorphism or computed coercion.
capturedArgumentContext :: Env -> String -> Expr -> C (Maybe Type)
capturedArgumentContext env name expression = do
  context <- Variable . ("capture:" ++) <$> fresh
  probe (M.insert name (Monomorphic context) env) expression
  Just <$> resolve context
  where
    -- Later captures participate through fresh monomorphic slots. Their
    -- actual values are still checked by their own strict let, in order.
    -- Infer the complete callback so partial application, composition and
    -- explicit function annotations all share ordinary argument inference.
    probe scope expression = case unlocated expression of
      MatchExpr value [MatchBranch tag [binder] body] | tag == letTag -> do
        ty <- if contextualLiteralArgument value || literalApplication value
          then Variable . ("capture:" ++) <$> fresh
          else infer scope value >>= resolve
        probe (M.insert binder (Monomorphic ty) scope) body
      Unary _ body -> probe scope body
      _ -> infer scope expression >> pure ()

matchScopesWithResult :: Env -> Maybe Type -> Expr -> [MatchBranch] -> C [Maybe (Env,M.Map String Type)]
matchScopesWithResult env result value [MatchBranch tag [name] body] | tag == letTag = do
  hint <- if contextualLiteralArgument value || literalApplication value then
      if "~lawspecAnyItem" `isPrefixOf` name then capturedArgumentContext env name body
      else if isLiteral value then constructorFieldContext name result body else pure Nothing
    else pure Nothing
  ty <- case hint of
    Just expected -> checkExpr env expected value >> resolve expected
    Nothing -> infer env value >>= resolve
  pure [Just (M.insert name (Monomorphic ty) env,M.empty)]
matchScopesWithResult env _ value branches = do
  ty <- infer env value >>= resolve
  let tags = [tag | MatchBranch tag _ _ <- branches]
  unless (distinct tags) (throwC "duplicate match constructor")
  resolved <- resolve ty
  -- Structural record patterns have already selected their sole product
  -- shape. An exhausted guarded matrix is incomplete, not an unknown type.
  case resolved of
    RecordShape _ | null branches -> throwC "non-exhaustive match"
    _ -> pure ()
  let parent = case resolved of Named n -> n; Applied n _ -> n; Application n _ -> n; _ -> ""
  declarations <- typesNamed parent
  declaration <- case declarations of
    [declaration] -> pure declaration
    _ -> throwC "matching requires a known data type"
  scopes <- mapM (scope ty) branches
  -- Every constructor that could build the scrutinee needs a branch, unless
  -- a matcher's wildcard branch _ stands for the others (matchWildcard).
  unless ("_" `elem` tags) $ forM_ (Core.dataConstructors declaration) $ \c ->
    unless (any (`elem` tags) [Core.constructorName c, Core.idText (Core.constructorId c)]) $ do
      saved <- get
      reachable <- matchConstructor ty (Core.idText (Core.constructorId c))
      put saved
      when (reachable /= Nothing) (throwC "non-exhaustive match")
  pure scopes
  where
    scope _ (MatchBranch "_" _ _) = pure (Just (env, M.empty))
    scope ty (MatchBranch tag names _) = do
      unless (distinct names) (throwC "duplicate match binder")
      found <- matchConstructor ty tag
      case found of
        Nothing -> pure Nothing
        Just (fields, local) -> do
          unless (length names == length fields) (throwC ("wrong match constructor arity: " ++ tag))
          pure (Just (M.union (monoEnvironment (zip names fields)) env, local))

-- The constructors a matcher's wildcard branch _ stands for: those of the
-- scrutinee's type that no other branch names and that can build a value of
-- it, by identity, with their field types.
matchWildcard :: Type -> [String] -> C [(String, [Type])]
matchWildcard ty tags = do
  resolved <- resolve ty
  let parent = case resolved of Named n -> n; Applied n _ -> n; Application n _ -> n; _ -> ""
  known <- typesNamed parent
  fmap concat $ forM [c | d <- known, c <- Core.dataConstructors d,
      not (any (`elem` tags) [Core.constructorName c, Core.idText (Core.constructorId c)])] $ \c -> do
    found <- matchConstructor resolved (Core.idText (Core.constructorId c))
    pure [(Core.idText (Core.constructorId c), fields) | Just (fields, _) <- [found]]

-- | Payload callbacks are scoped over declared type arguments, never over fixed
-- fields whose concrete types happen to coincide with an argument.
payloadArguments :: Type -> C [Type]
payloadArguments ty = do
  (name,arguments) <- case baseType ty of
    Named name -> pure (name,[])
    Applied name argument -> pure (name,[argument])
    Application name arguments -> pure (name,arguments)
    _ -> throwC "payload predicates require a data type"
  count <- if name `elem` ["Nullable","Optional"] then pure 1 else
    typesNamed name >>= \declarations -> case [length (Core.dataParameters d) | d <- declarations] of
      [count] -> pure count
      _ -> throwC "payload predicates require a registered data type"
  unless (count == length arguments) (throwC "payload data type arity mismatch")
  pure arguments

-- | Literal collection arguments take an element context without first
-- committing their values to a default scalar type. Computed collections and
-- explicit annotations retain their own types.
collectionLiteral :: Expr -> Bool
collectionLiteral value = case unlocated value of
  ListLit _ -> True
  _ -> literalApplication value

collectionTypesWith :: Env -> Expr -> Maybe Type -> C (Type,Type)
collectionTypesWith env value hint = case (unlocated value,hint) of
  (ListLit _,Just element) -> contextual (Applied "List" element)
  (_,Just element) | literalApplication value -> do
    let (function,arguments) = application value
    signature <- infer env function >>= resolve
    result <- resultType (length arguments) signature
    parameter <- finiteCollectionElement result
    unify parameter element
    resolve result >>= contextual
  _ -> do
    collection <- infer env value >>= resolve
    element <- finiteCollectionElement collection
    pure (collection,element)
  where
    contextual collection = do
      checkExpr env collection value
      resolved <- resolve collection
      element <- finiteCollectionElement resolved
      pure (resolved,element)
    resultType 0 ty = pure ty
    resultType count (Arrow _ result) = resultType (count-1) result
    resultType _ _ = throwC "a collection constructor has insufficient arguments"

membershipTypes :: Env -> Expr -> Expr -> C (Type,Type)
membershipTypes env value collection = do
  hint <- if collectionLiteral collection && not (numericLiteral value)
    then Just <$> (infer env value >>= resolve) else pure Nothing
  selected@(_,element) <- collectionTypesWith env collection hint
  checkExpr env element value
  pure selected

iterationTypes :: Env -> Expr -> String -> Expr -> C (Type,Type)
iterationTypes env value binder predicate = do
  hint <- if "~lawspecAnyItem" `isPrefixOf` binder && collectionLiteral value then do
      element <- Variable . ("iteration:" ++) <$> fresh
      checkExpr (M.insert binder (Monomorphic element) env) (Named "Bool") predicate
      Just <$> resolve element
    else case callback predicate of
     Just function | collectionLiteral value, binder `notElem` exprVars function -> do
       signature <- infer env function >>= resolve
       case signature of
         Arrow element result -> unify result (Named "Bool") >> pure (Just element)
         _ -> throwC "any requires an element predicate returning Bool"
     _ -> pure Nothing
  collectionTypesWith env value hint
  where
    callback expression = case unlocated expression of
      Unary "!" body -> callback body
      Apply function argument | unlocated argument == Var binder -> Just function
      _ -> Nothing

-- | Only registered finite collection identities supply element iteration.
-- Maps select keys, values or entries explicitly; text substring matching is
-- a separate operation. Never infer iteration from a user type's field shape.
finiteCollectionElement :: Type -> C Type
finiteCollectionElement ty = case baseType ty of
  Applied "List" element -> pure element
  Applied name element | collectionName name `elem` map Just ["Set","EqSet","Queue","Stack","Deque"] -> pure element
  Named "Bytes" -> pure (Named "UInt8")
  Application name _ | collectionName name == Just "KeyVal" ->
    throwC "map iteration requires explicit prelude.keys, prelude.values or prelude.entries"
  _ -> throwC ("element iteration requires a finite collection, not " ++ prettyType ty)

-- | A collections-unit type's short name.
collectionName :: String -> Maybe String
collectionName n = stripPrefix (collectionsUnit ++ "::type::") n

-- | No name twice, in O(n log n): a record may have hundreds of fields.
distinct :: [String] -> Bool
distinct names = length names == Set.size (Set.fromList names)
