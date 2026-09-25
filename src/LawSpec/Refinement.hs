module LawSpec.Refinement where

import LawSpec.Model
import LawSpec.Scalar
import Control.Monad (unless, when, foldM)
import qualified Data.Map.Strict as M
import Data.List (nub, intercalate)

lowerUnit :: Unit -> Either String Unit
lowerUnit u = do
  let rs = refinements u; table = M.fromList [(refinementName r,r) | r <- rs]
  unless (length rs == M.size table) (Left "duplicate refinement")
  mapM_ (validateDeclaration table) rs
  fs <- mapM (\(n,t) -> (,) n <$> expandType table [] M.empty M.empty t) (functions u)
  ls <- mapM (lowerLaw table) (laws u)
  cs <- mapM contractFor fs
  let active = [c | c <- cs, not (null (contractPreconditions c) && null (contractPostconditions c))]
      checks = map refinementCheck rs
  checks' <- mapM (lowerLaw table) checks
  pure u{functions=map (\(n,t) -> (n,baseType t)) fs, contracts=active, laws=ls ++ map contractLaw active ++ checks'}

validateDeclaration :: M.Map String Refinement -> Refinement -> Either String ()
validateDeclaration table r = do
  let ps = refinementParameters r; ns = map fst ps
  unless (length ns == length (nub ns)) (Left "duplicate refinement parameter")
  _ <- foldM (\known (n,t) -> do
       when (t /= Named "Type" && any (`elem` dropWhile (/= n) ns) (typeNames t)) (Left "refinement parameter refers to itself or a later parameter")
       pure (n:known)) [] ps
  let ts = M.fromList [(n,Variable n) | (n,Named "Type") <- ps]
  _ <- expandType table [refinementName r] ts M.empty (refinementBody r)
  pure ()

-- A synthetic generic declaration checks unused aliases as well as instantiated ones.
refinementCheck :: Refinement -> Law
refinementCheck r = Law ("refinement " ++ refinementName r) ps cs (Forall [("_refinementValue",body)] (Holds (BoolLit True))) "" "" [] [] (Location "<refinement>" 1 1)
  where ts = M.fromList [(n,Variable n) | (n,Named "Type") <- refinementParameters r]
        sub = substituteType ts M.empty
        ps = [(if t == Named "Type" then "_type_" ++ n else n, if t == Named "Type" then Variable n else sub t) | (n,t) <- refinementParameters r] ++ [("_declaration",Named "Unit")]
        cs = [Capability n (sub t) | Capability n t <- refinementRequirements r]
        body = sub (refinementBody r)

lowerLaw :: M.Map String Refinement -> Law -> Either String Law
lowerLaw table l = do
  ps <- mapM (\(n,t) -> (,) n <$> expandType table [] M.empty M.empty t) (parameters l)
  d <- walk (definition l)
  pure l{parameters=ps,definition=d}
  where walk (Forall qs d) = Forall <$> mapM (\(n,t) -> (,) n <$> expandType table [] M.empty M.empty t) qs <*> walk d
        walk (And a b) = And <$> walk a <*> walk b
        walk (Implies a b) = Implies a <$> walk b
        walk d = pure d

expandType :: M.Map String Refinement -> [String] -> M.Map String Type -> M.Map String Expr -> Type -> Either String Type
expandType table stack ts vs t = case substituteType ts vs t of
  RefinementApp n args -> do
    when (n `elem` stack) (Left ("recursive refinement: " ++ n))
    r <- maybe (Left ("unknown refinement: " ++ n)) Right (M.lookup n table)
    unless (length args == length (refinementParameters r)) (Left ("wrong refinement arity: " ++ n))
    (types,values,checks,required) <- foldM bind (M.empty,M.empty,[],[]) (zip (refinementParameters r) args)
    body <- expandType table (n:stack) types values (refinementBody r)
    let cs = [Capability c (substituteType types values a) | Capability c a <- refinementRequirements r]
    pure (if null checks then Qualified (required++cs) body else CheckedType checks (Qualified (required++cs) body))
  Refined n a p -> Refined n <$> expandType table stack M.empty M.empty a <*> pure p
  Applied n a -> Applied n <$> expandType table stack M.empty M.empty a
  Arrow a b -> Arrow <$> expandType table stack M.empty M.empty a <*> expandType table stack M.empty M.empty b
  CheckedType ps a -> CheckedType ps <$> expandType table stack M.empty M.empty a
  Qualified cs a -> Qualified cs <$> expandType table stack M.empty M.empty a
  a -> pure a
  where
    bind (types,values,checks,required) ((n,Named "Type"),TypeArgument a) = do
      a' <- expandType table stack M.empty M.empty a
      pure (M.insert n a' types,values,checks,required)
    bind (types,values,checks,required) ((n,t'),ValueArgument e) = do
      t'' <- expandType table stack types values t'
      pure (types,M.insert n (Annotate e (baseType t'')) values,checks ++ typePredicates (Annotate e (baseType t'')) t'',required ++ typeConstraints t'')
    bind _ _ = Left "refinement argument kind mismatch (type versus value)"

substituteType :: M.Map String Type -> M.Map String Expr -> Type -> Type
substituteType ts vs = go where
  go (Named n) = M.findWithDefault (Named n) n ts
  go (Variable n) = M.findWithDefault (Variable n) n ts
  go (Refined n t p) = Refined fresh (go t) (expr <$> p)
    where fresh = if n `elem` concatMap exprVars (M.elems vs) then head ["_ref_" ++ n ++ show i | i <- [0::Int ..], ("_ref_" ++ n ++ show i) `notElem` concatMap exprVars (M.elems vs)] else n
          expr = mapExprTypes go . replaceExprVars (M.toList (M.delete n vs)) . replaceExprVars [(n,Var fresh)]
  go (Arrow a b) = Arrow (go a) (go b)
  go (Applied n a) = Applied n (go a)
  go (CheckedType ps a) = CheckedType (map (mapExprTypes go . replaceExprVars (M.toList vs)) ps) (go a)
  go (Qualified cs a) = Qualified [Capability n (go t) | Capability n t <- cs] (go a)
  go (RefinementApp n args) = RefinementApp n [case a of TypeArgument t -> TypeArgument (go t); ValueArgument e -> ValueArgument (mapExprTypes go (replaceExprVars (M.toList vs) e)) | a <- args]

contractFor :: (String,Type) -> Either String Contract
contractFor (n,t) = do
  let (args,result) = functionType t
      binder fallback (Refined name a p) = (name,Refined name a p)
      binder fallback a = (fallback,a)
      as = [binder ("_argument" ++ show i) a | (i,a) <- zip [0::Int ..] args]
      r = binder "_result" result
  unless (length (map fst as ++ [fst r]) == length (nub (map fst as ++ [fst r]))) (Left (n ++ ": duplicate dependent binder"))
  pure (Contract n as r (concat [typePredicates (Var name) a | (name,a) <- as]) (typePredicates (Var (fst r)) (snd r)))

contractLaw :: Contract -> Law
contractLaw c = Law ("contract " ++ contractName c) [] [] (Forall (contractArguments c) (Holds (Apply (Var "prelude.checked") invocation))) (contractName c ++ " :: " ++ intercalate " -> " (map (prettyType . snd) (contractArguments c ++ [contractResult c]))) "" [] [] (Location "<contract>" 1 1)
  where invocation = foldl Apply (Var (contractName c)) (map (Var . fst) (contractArguments c))

typeNames :: Type -> [String]
typeNames (Named n) = [n]
typeNames (Variable n) = [n]
typeNames (Arrow a b) = typeNames a ++ typeNames b
typeNames (Applied _ t) = typeNames t
typeNames (Refined _ t p) = typeNames t ++ maybe [] exprVars p
typeNames (Qualified _ t) = typeNames t
typeNames (CheckedType ps t) = concatMap exprVars ps ++ typeNames t
typeNames (RefinementApp _ args) = concat [case a of TypeArgument t -> typeNames t; ValueArgument e -> exprVars e | a <- args]

-- Isolate affine occurrences of the current integer input. All other terms may
-- be arbitrary pure expressions over the preceding inputs.
planDomain :: [(String,Type)] -> Input -> DomainPlan
planDomain env i = DomainPlan i (if isIntegerType (inputType i) then concatMap bounds (inputRefinements i) else [])
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

-- Optimizations must never evaluate a partial expression before its guard.
-- Unrecognized expressions remain in the authoritative short-circuit predicate.
safeDomainExpr :: [(String,Type)] -> Expr -> Bool
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
