-- | Named refinements are expanded into the refined types and checked contracts
-- they stand for, so later stages see only ordinary refined types and every
-- target checks the same predicate.
module LawSpec.Refinement where

import LawSpec.Model
import LawSpec.Scalar
import Control.Monad (unless, when, foldM)
import qualified Data.Map.Strict as M
import Data.List (nub, intercalate)

-- | A unit with no imports knows only its own data types.
lowerUnit :: Unit -> Either String Unit
lowerUnit = lowerUnitWith M.empty

-- | Imported data types are known by their qualified names.
lowerUnitWith :: M.Map String DataTypeDeclaration -> Unit -> Either String Unit
lowerUnitWith imported u = do
  let rs = refinements u
      (structures, table) = unitTables imported u
  unless (length rs == M.size table) (Left "duplicate refinement")
  mapM_ (validateDeclaration structures table) rs
  fs <- mapM (\(n,t) -> (,) n <$> expandType structures table [] M.empty M.empty t) (functions u)
  -- Keep definition refinements until template proof and specialization derive
  -- their closed contracts. Adapter signatures become generated contract laws.
  definitions <- mapM (\d -> do
    args <- mapM (\(n,t) -> (,) n <$> expandType structures table [] M.empty M.empty t) (functionArguments d)
    result <- expandType structures table [] M.empty M.empty (functionResult d)
    requirements <- mapM (\(Capability name ty) ->
      Capability name <$> expandType structures table [] M.empty M.empty ty) (functionRequirements d)
    pure d{functionArguments=args,functionResult=result,functionRequirements=requirements}) (functionDefinitions u)
  ls <- mapM (lowerLaw structures table) (laws u)
  ds <- mapM (\d -> do
    constructors <- mapM (\c -> do
      fields <- mapM (\(n,t) -> (,) n <$> expandType structures table [] M.empty M.empty t) (dataConstructorFields c)
      pure c{dataConstructorFields=fields}) (dataTypeConstructors d)
    pure d{dataTypeConstructors=constructors}) (dataTypes u)
  -- Harness declarations carry the same source types as law binders. Expand
  -- aliases and indexed applications before specialization, including bind
  -- inputs and named strategies that are reached through other strategies.
  let expand = expandType structures table [] M.empty M.empty
      generator gen = case gen of
        GenAny ty -> GenAny <$> traverse expand ty
        GenBind name ty from body -> GenBind name <$> expand ty <*> generator from <*> generator body
        GenFrequency choices -> GenFrequency <$> mapM (\(weight,body) -> (,) weight <$> generator body) choices
        GenSuchThat inner predicate limit -> (\body -> GenSuchThat body predicate limit) <$> generator inner
        other -> pure other
      item entry = case entry of
        HarnessStrategy strategy -> do
          ty <- expand (strategyType strategy)
          body <- generator (strategyBody strategy)
          pure (HarnessStrategy strategy{strategyType=ty,strategyBody=body})
        other -> pure other
  harness <- traverse (\h -> do entries <- mapM item (harnessItems h); pure h{harnessItems=entries}) (unitHarness u)
  -- An ability operation's signature may name refinements like any other
  -- signature; the refined types reach the operation's implied laws and
  -- every handler, and Core sees their base types.
  declaredAbilities <- mapM (\a -> do
    operations <- mapM (\(n,t) -> (,) n <$> expand t) (abilityOperations a)
    failures <- mapM (\(n,t) -> (,) n <$> expand t) (abilityFailures a)
    resource <- traverse expand (abilityResource a)
    pure a{abilityOperations=operations,abilityFailures=failures,abilityResource=resource}) (abilities u)
  -- The ability types a row, a use, a law's handler choice or a handler
  -- names are expanded too: `uses Store Count` is Store at Count's base
  -- type. What Count adds is the operation result checks
  -- (LawSpec.OperationChecks) and the handlers' result laws.
  let ability ty = case ty of
        Applied name argument -> Applied name . baseType <$> expand argument
        Application name arguments -> Application name <$> mapM (fmap baseType . expand) arguments
        other -> pure other
      row (name,types) = (,) name <$> mapM ability types
  rows <- mapM row (abilityRows u)
  uses <- mapM row (declaredUses u)
  assignments <- mapM (\(name,choices) -> (,) name <$> mapM (\(ty,choice) -> (\t -> (t,choice)) <$> ability ty) choices) (lawAssignments u)
  handlers <- mapM (\h -> do
    answered <- ability (handlerAbility h)
    also <- mapM ability (handlerAlso h)
    state <- traverse (\(name,ty,start) -> (\t -> (name,baseType t,start)) <$> expand ty) (handlerState h)
    pure h{handlerAbility=answered,handlerAlso=also,handlerState=state}) (handlerDeclarations u)
  plans <- mapM (\(name,plan) -> do
    draws <- mapM (\(input,strategy,ty,body) -> (,,,) input strategy <$> expand ty <*> generator body) (planDraws plan)
    pure (name,plan{planDraws=draws})) (lawHarness u)
  -- Ability operations are answered by handlers, not adapters: no contract.
  cs <- mapM contractFor [(n,t) | (n,t) <- fs, n `notElem` map functionName definitions, n `notElem` operationNames u]
  let active = [c | c <- cs, not (null (contractPreconditions c) && null (contractPostconditions c))]
      checks = map refinementCheck rs
  checks' <- mapM (lowerLaw structures table) checks
  -- A handle cannot be generated, so an adapter taking or returning one
  -- keeps its contract (checked at each call) but gets no contract law.
  let handleNames = handles u ++ [n | (n, d) <- M.toList imported, null (dataTypeConstructors d)]
      mentionsHandle t = any (\n -> n `elem` handleNames || any (\h -> ("::type::" ++ n) `isSuffixOf'` h) handleNames) (typeNames t)
      generated c = not (any (mentionsHandle . snd) (contractArguments c ++ [contractResult c]))
      isSuffixOf' a b = reverse a == take (length a) (reverse b)
  pure u{functions=map (\(n,t) -> (n,baseType t)) fs, contracts=active, laws=ls ++ map contractLaw (filter generated active) ++ checks', dataTypes=ds, functionDefinitions=definitions,unitHarness=harness,lawHarness=plans,abilities=declaredAbilities,abilityRows=rows,declaredUses=uses,lawAssignments=assignments,handlerDeclarations=handlers}

-- | A unit's data types (with imported ones, by qualified name) and its
-- refinements, by name: what expanding one of its types needs.
unitTables :: M.Map String DataTypeDeclaration -> Unit -> (M.Map String DataTypeDeclaration, M.Map String Refinement)
unitTables imported u =
  ( M.union imported $ M.fromList [(dataTypeName d,d{dataTypeConstructors=
      [c{dataConstructorName=unitName u ++ "::type::" ++ dataTypeName d ++ "::" ++ dataConstructorName c}
      | c <- dataTypeConstructors d]}) | d <- dataTypes u]
  , M.fromList [(refinementName r,r) | r <- refinements u] )

-- | A type of a unit with its refinement aliases expanded.
expandUnitType :: M.Map String DataTypeDeclaration -> Unit -> Type -> Either String Type
expandUnitType imported u = let (structures, table) = unitTables imported u
  in expandType structures table [] M.empty M.empty

-- | A refinement that is ill-formed is reported once, at its declaration, not at
-- every use.
validateDeclaration :: M.Map String DataTypeDeclaration -> M.Map String Refinement -> Refinement -> Either String ()
validateDeclaration structures table r = do
  let ps = refinementParameters r; ns = map fst ps
  unless (length ns == length (nub ns)) (Left "duplicate refinement parameter")
  _ <- foldM (\known (n,t) -> do
       when (t /= Named "Type" && any (`elem` dropWhile (/= n) ns) (typeNames t)) (Left "refinement parameter refers to itself or a later parameter")
       pure (n:known)) [] ps
  let ts = M.fromList [(n,Variable n) | (n,Named "Type") <- ps]
  _ <- expandType structures table [refinementName r] ts M.empty (refinementBody r)
  pure ()

-- | A synthetic generic declaration checks unused aliases as well as instantiated ones.
refinementCheck :: Refinement -> Law
refinementCheck r = Law ("refinement " ++ refinementName r) ps cs (Forall [("_refinementValue",body)] (Holds (BoolLit True))) "" "" [] [] (Location "<refinement>" 1 1) [] emptyLawMetadata
  where ts = M.fromList [(n,Variable n) | (n,Named "Type") <- refinementParameters r]
        sub = substituteType ts M.empty
        ps = [(if t == Named "Type" then "_type_" ++ n else n, if t == Named "Type" then Variable n else sub t) | (n,t) <- refinementParameters r] ++ [("_declaration",Named "Unit")]
        cs = [Capability n (sub t) | Capability n t <- refinementRequirements r]
        body = sub (refinementBody r)

-- | Law parameters may name refinements, and the testing plan needs the
-- predicates themselves to generate and filter inputs.
lowerLaw :: M.Map String DataTypeDeclaration -> M.Map String Refinement -> Law -> Either String Law
lowerLaw structures table l = do
  ps <- mapM (\(n,t) -> (,) n <$> expandType structures table [] M.empty M.empty t) (parameters l)
  d <- walk (definition l)
  pure l{parameters=ps,definition=d}
  where walk (Forall qs d) = Forall <$> mapM (\(n,t) -> (,) n <$> expandType structures table [] M.empty M.empty t) qs <*> walk d
        walk (Exists qs d) = Exists <$> mapM (\(n,t) -> (,) n <$> expandType structures table [] M.empty M.empty t) qs <*> walk d
        walk (Not d) = Not <$> walk d
        walk (And a b) = And <$> walk a <*> walk b
        walk (Implies a b) = Implies a <$> walk b
        walk d = pure d

-- | Refinements may be parameterised and nested; expansion substitutes the
-- arguments and refuses a refinement that mentions itself, which would never
-- terminate.
expandType :: M.Map String DataTypeDeclaration -> M.Map String Refinement -> [String] -> M.Map String Type -> M.Map String Expr -> Type -> Either String Type
expandType structures table stack ts vs t = case substituteType ts vs t of
  RefinementApp n args -> do
    when (n `elem` stack) (Left ("recursive refinement: " ++ n))
    r <- maybe (Left ("unknown refinement: " ++ n)) Right (M.lookup n table)
    unless (length args == length (refinementParameters r)) (Left ("wrong refinement arity: " ++ n))
    (types,values,checks,required) <- foldM bind (M.empty,M.empty,[],[]) (zip (refinementParameters r) args)
    body <- expandType structures table (n:stack) types values (refinementBody r)
    let cs = [Capability c (substituteType types values a) | Capability c a <- refinementRequirements r]
    pure (if null checks then Qualified (required++cs) body else CheckedType checks (Qualified (required++cs) body))
  Refined n a p -> Refined n <$> expandType structures table stack M.empty M.empty a <*> pure p
  Applied n a -> do
    a' <- expandType structures table stack M.empty M.empty a
    let application = Applied n a'
    if n `elem` ["List","Maybe","Nullable","Optional"] || not (hasValueRefinements a')
      then pure application else namedPredicates n [a'] application
  Application n args -> do
    args' <- mapM (expandType structures table stack M.empty M.empty) args
    let application = Application n args'
    if n == "Either" || not (any hasValueRefinements args')
      then pure application else namedPredicates n args' application
  Arrow a b -> Arrow <$> expandType structures table stack M.empty M.empty a <*> expandType structures table stack M.empty M.empty b
  record@(RecordShape fields) -> withRecordFields record <$> mapM (\field -> do
    ty <- expandType structures table stack M.empty M.empty (recordFieldType field)
    pure field{recordFieldType=ty}) fields
  CheckedType ps a -> CheckedType ps <$> expandType structures table stack M.empty M.empty a
  Qualified cs a -> Qualified cs <$> expandType structures table stack M.empty M.empty a
  a -> pure a
  where
    namedPredicates name arguments application = do
      declaration <- maybe (Left "structural element refinements require element predicates") Right
        (M.lookup name structures)
      unless (length arguments == length (dataTypeParameters declaration))
        (Left ("wrong data type arity: " ++ name))
      let probe = "$lawspecPayload"
          free = concatMap (concatMap exprVars . typePredicates (Var probe)) arguments
          fresh name = head [name ++ replicate n '_' | n <- [0..],
            name ++ replicate n '_' `notElem` free]
          binder = fresh probe
          callbacks = [(fresh ("$lawspecArgument" ++ show index),argument)
            | (index,argument) <- zip [0 :: Int ..] arguments]
          predicate (local,argument) = (local,
            foldr (Binary "&&") (BoolLit True) (typePredicates (Var local) argument))
      pure (Refined binder application
        (Just (AllPayloadsExpr (Var binder) (map predicate callbacks))))

    bind (types,values,checks,required) ((n,Named "Type"),TypeArgument a) = do
      a' <- expandType structures table stack M.empty M.empty a
      pure (M.insert n a' types,values,checks,required)
    bind (types,values,checks,required) ((n,t'),ValueArgument e) = do
      t'' <- expandType structures table stack types values t'
      pure (types,M.insert n (Annotate e (baseType t'')) values,checks ++ typePredicates (Annotate e (baseType t'')) t'',required ++ typeConstraints t'')
    bind _ _ = Left "refinement argument kind mismatch (type versus value)"

-- | A type without value predicates needs no runtime check, so emitters skip the
-- validation they would otherwise generate.
hasValueRefinements :: Type -> Bool
hasValueRefinements ty = case ty of
  Refined _ inner predicate -> maybe False (const True) predicate || hasValueRefinements inner
  CheckedType predicates inner -> not (null predicates) || hasValueRefinements inner
  Qualified _ inner -> hasValueRefinements inner
  Applied _ inner -> hasValueRefinements inner
  Application _ arguments -> any hasValueRefinements arguments
  RecordShape fields -> any (hasValueRefinements . recordFieldType) fields
  Arrow a b -> hasValueRefinements a || hasValueRefinements b
  _ -> False

-- | Bound names are renamed apart when a predicate's binder would capture an
-- argument, so substitution never changes a predicate's meaning.
substituteType :: M.Map String Type -> M.Map String Expr -> Type -> Type
substituteType ts vs = go where
  go (Named n) = M.findWithDefault (Named n) n ts
  go (Variable n) = M.findWithDefault (Variable n) n ts
  go record@(RecordShape fields) = withRecordFields record (scopeRecordFields
    (concatMap typeValueVars (M.elems ts)) (M.toList vs)
    (\active -> substituteType ts (M.fromList active)) fields)
  go (Refined n t p) = Refined fresh (go t) (expr <$> p)
    where forbidden = concatMap exprVars (M.elems vs) ++ concatMap typeValueVars (M.elems ts)
          used = forbidden ++ typeValueVars t ++ maybe [] exprVars p ++ M.keys vs
          fresh = if n `elem` forbidden then head ["_ref_" ++ n ++ show i | i <- [0::Int ..], ("_ref_" ++ n ++ show i) `notElem` used] else n
          expr = expression (M.delete n vs) . replaceExprVars [(n,Var fresh)]
  go (Arrow a b) = Arrow (go a) (go b)
  go (Applied n a) = Applied n (go a)
  go (Application n args) = Application n (map go args)
  go (CheckedType ps a) = CheckedType (map (expression vs) ps) (go a)
  go (Qualified cs a) = Qualified [Capability n (go t) | Capability n t <- cs] (go a)
  go (RefinementApp n args) = RefinementApp n [case a of TypeArgument t -> TypeArgument (go t); ValueArgument e -> ValueArgument (expression vs e) | a <- args]
  expression values = substituteExpr (concatMap typeValueVars (M.elems ts))
    (\active -> substituteType ts (M.fromList active)) (M.toList values)

-- | Synthetic predicate binders are not user-declared dependent argument names.
-- '$' is unavailable in source identifiers, so it cannot capture a source binder.
internalBinder :: String -> Bool
internalBinder ('$':_) = True
internalBinder _ = False

-- | An adapter whose signature carries refinements makes a promise about every
-- call, so its signature becomes a contract each target checks.
contractFor :: (String,Type) -> Either String Contract
contractFor (n,t) = do
  let (args,result) = functionType t
      binder fallback t@(Refined name _ _) = (if internalBinder name then fallback else name,t)
      binder fallback a = (fallback,a)
      as = [binder ("_argument" ++ show i) a | (i,a) <- zip [0::Int ..] args]
      r = binder "_result" result
  unless (length (map fst as ++ [fst r]) == length (nub (map fst as ++ [fst r]))) (Left (n ++ ": duplicate dependent binder"))
  pure (Contract n as r (concat [typePredicates (Var name) a | (name,a) <- as]) (typePredicates (Var (fst r)) (snd r)))

-- | Definitions already bind their arguments explicitly. Preserve those names
-- when deriving dependent contracts instead of inventing signature binders.
definitionContractFor :: FunctionDefinition -> Either String Contract
definitionContractFor definition = do
  let arguments = functionArguments definition
      resultType = functionResult definition
      names = map fst arguments
      resultName ty = case ty of
        Refined name _ _ | not (internalBinder name) -> name
        Qualified _ inner -> resultName inner
        CheckedType _ inner -> resultName inner
        _ -> head ["_result" ++ replicate i '_' | i <- [0..],
          "_result" ++ replicate i '_' `notElem` names]
      result = (resultName resultType,resultType)
  unless (length names == length (nub names)) (Left "duplicate definition argument")
  unless (fst result `notElem` names) (Left "definition result binder shadows an argument")
  pure (Contract (functionName definition) arguments result
    (concat [typePredicates (Var name) ty | (name,ty) <- arguments])
    (typePredicates (Var (fst result)) resultType))

-- | A contract is tested like any law, so it gets evidence and a generated test
-- on every target. ref:DEC-evidence-statuses
contractLaw :: Contract -> Law
contractLaw c = Law ("contract " ++ contractName c) [] [] (Forall (contractArguments c) (Holds (Apply (Var "prelude.checked") invocation))) (contractName c ++ " :: " ++ intercalate " -> " (map (prettyType . snd) (contractArguments c ++ [contractResult c]))) "" [] [] (Location "<contract>" 1 1) [] emptyLawMetadata
  where invocation = foldl Apply (Var (contractName c)) (map (Var . fst) (contractArguments c))

-- | Dependency order between declarations follows the names their types mention.
typeNames :: Type -> [String]
typeNames (Named n) = [n]
typeNames (Variable n) = [n]
typeNames (Arrow a b) = typeNames a ++ typeNames b
typeNames (Applied _ t) = typeNames t
typeNames (Application _ ts) = concatMap typeNames ts
typeNames (RecordShape fields) = concatMap (typeNames . recordFieldType) fields
typeNames (Refined _ t p) = typeNames t ++ maybe [] exprVars p
typeNames (Qualified _ t) = typeNames t
typeNames (CheckedType ps t) = concatMap exprVars ps ++ typeNames t
typeNames (RefinementApp _ args) = concat [case a of TypeArgument t -> typeNames t; ValueArgument e -> exprVars e | a <- args]

-- | Isolate affine occurrences of the current integer input. All other terms may
-- be arbitrary pure expressions over the preceding inputs.
planDomain :: [(String,Type)] -> Input -> DomainPlan
planDomain env i = DomainPlan i (if isIntegerType (inputType i) then concatMap (bounds . stripLocations) (inputRefinements i) else [])
  where
    variable = inputId i
    isIntegerType (Named n) = isInteger n
    isIntegerType _ = False
    bounds (Binary "&&" a b) = bounds a ++ bounds b
    bounds (Binary op a b) | op `elem` ["<","<=",">",">=","=="] =
      case affine (Binary "-" a b) of
        Just (k,c) | k /= 0, safeDomainExpr env c -> [(if k < 0 then reverseOp op else op, Binary "/" (Unary "-" c) (Number k))]
        _ -> []
    bounds _ = []
    affine e | variable `notElem` exprVars e = Just (0,e)
    affine (Var n) | n == variable = Just (1,Number 0)
    affine (Unary "-" a) = do (k,c) <- affine a; pure (-k,Unary "-" c)
    affine (Binary op a b) | op `elem` ["+","-"] = do
      (ka,ca) <- affine a; (kb,cb) <- affine b
      pure (if op == "+" then ka+kb else ka-kb,Binary op ca cb)
    affine (Binary "*" (Number k) a) = do (v,c) <- affine a; pure (k*v,Binary "*" (Number k) c)
    affine (Binary "*" a (Number k)) = affine (Binary "*" (Number k) a)
    affine _ = Nothing
    reverseOp "<" = ">"
    reverseOp "<=" = ">="
    reverseOp ">" = "<"
    reverseOp ">=" = "<="
    reverseOp op = op

-- | Optimizations must never evaluate a partial expression before its guard.
-- Unrecognized expressions remain in the authoritative short-circuit predicate.
safeDomainExpr :: [(String,Type)] -> Expr -> Bool
safeDomainExpr env (Located _ e) = safeDomainExpr env e
safeDomainExpr env (Annotate (Var n) t) = lookup n env == Just (baseType t)
safeDomainExpr env (Unary _ a) = safeDomainExpr env a
safeDomainExpr env (Binary op a b) | op `elem` ["+","-","*","==","!=","<","<=",">",">="] = safeDomainExpr env a && safeDomainExpr env b
safeDomainExpr env (Binary op a (Number n)) | op `elem` ["/","quot","rem"], n /= 0 = safeDomainExpr env a
safeDomainExpr _ (Var _) = True
safeDomainExpr _ (Number _) = True
safeDomainExpr _ (DecimalNumber _ _) = True
safeDomainExpr _ (StringLit _) = True
safeDomainExpr _ (BoolLit _) = True
safeDomainExpr _ (ScalarLit _) = True
safeDomainExpr _ (TypeBound _ _) = True
safeDomainExpr _ _ = False
