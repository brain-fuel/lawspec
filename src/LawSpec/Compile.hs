module LawSpec.Compile (compile, prettyExpanded, metadataText, normal) where

import LawSpec.Model
import LawSpec.Parser
import LawSpec.Prelude
import Control.Monad.State.Strict
import Control.Monad (unless, when, zipWithM_, forM, forM_)
import qualified Data.Map.Strict as M
import Data.List (nub, intercalate, uncons)
import Data.Char (isLower)

data CS = CS { substitutions :: M.Map String Type, counter :: Int, obligations :: [Type] }
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
resolve t = pure t
occurs :: String -> Type -> Bool
occurs n (Variable m) = n == m
occurs n (Arrow a b) = occurs n a || occurs n b
occurs _ _ = False
unify :: Type -> Type -> C ()
unify a b = do
  x <- resolve a; y <- resolve b
  case (x,y) of
    _ | x == y -> pure ()
    (Variable n,t) -> bind n t
    (t,Variable n) -> bind n t
    (Arrow p q,Arrow r s) -> unify p r >> unify q s
    _ -> throwC ("type mismatch: " ++ prettyType x ++ " and " ++ prettyType y)
  where bind n t | occurs n t = throwC "infinite type"
                 | otherwise = modify (\s -> s{substitutions=M.insert n t (substitutions s)})
infer :: Env -> Expr -> C Type
infer env (Var n) = maybe (throwC ("unknown value: " ++ n)) pure (M.lookup n env)
infer _ (Number n) | n < -2147483648 || n > 2147483647 = throwC "integer outside Int32 range"
                   | otherwise = pure (Named "Int32")
infer _ (StringLit s)
  | any (\c -> c >= '\xD800' && c <= '\xDFFF') s = throwC "Text cannot contain surrogate code points"
  | otherwise = pure (Named "Text")
infer _ (BoolLit _) = pure (Named "Bool")
infer env (Apply f x) = do
  ft <- infer env f; xt <- infer env x; r <- Variable . ("result:"++) <$> fresh
  unify ft (Arrow xt r); resolve r
infer env (Compose f g) = do
  a <- Variable . ("a:"++) <$> fresh; b <- Variable . ("b:"++) <$> fresh; c <- Variable . ("c:"++) <$> fresh
  ft <- infer env f; gt <- infer env g
  unify ft (Arrow b c); unify gt (Arrow a b); pure (Arrow a c)
rename :: String -> Type -> Type
rename p (Variable n) = Variable (p ++ ":" ++ n)
rename p (Arrow a b) = Arrow (rename p a) (rename p b)
rename _ t = t
subst :: M.Map String Expr -> Expr -> Expr
subst m (Var n) = M.findWithDefault (Var n) n m
subst m (Apply f x) = Apply (subst m f) (subst m x)
subst m (Compose f g) = Compose (subst m f) (subst m g)
subst _ e = e
normal :: Expr -> Expr
normal (Apply (Compose f g) x) = normal (Apply f (Apply g x))
normal (Apply f x) = Apply (normal f) (normal x)
normal (Compose f g) = Compose (normal f) (normal g)
normal e = e

type Table = M.Map (String,String) Law
expand :: Table -> String -> Env -> [String] -> Law -> [Expr] -> C ([Input], Expr, Expr, [Expr], [String])
expand table unit env stack law args = do
  let key = unit ++ "::" ++ lawName law
  when (key `elem` stack) (throwC ("recursive law expansion: " ++ intercalate " -> " (reverse (key:stack))))
  unless (length args == length (parameters law)) (throwC ("wrong argument count for law " ++ lawName law))
  p <- fresh
  let rt = rename p
  zipWithM_ (\(_,t) arg -> infer env arg >>= unify (rt t)) (parameters law) args
  modify (\s -> s{obligations=map rt (requirements law) ++ obligations s})
  let replacements = M.fromList (zip (map fst (parameters law)) args)
      walk e m (Forall qs d) = do
        bs <- forM qs $ \(n,t) -> do i <- ("_input"++) <$> fresh; pure (Input n i (rt t))
        let e' = M.union (M.fromList [(inputId b,inputType b) | b <- bs]) e
            m' = M.union (M.fromList [(inputName b,Var (inputId b)) | b <- bs]) m
        (rest,l,r,gs,tr) <- walk e' m' d
        pure (bs++rest,l,r,gs,tr)
      walk e m (Equal a b) = do
        let l = normal (subst m a); r = normal (subst m b)
        lt <- infer e l; rt' <- infer e r; unify lt rt'
        modify (\s -> s{obligations=lt:obligations s})
        pure ([],l,r,[],[])
      walk e m (Holds a) = walk e m (Equal a (BoolLit True))
      walk e m (Implies condition consequence) = do
        let guard = normal (subst m condition)
        infer e guard >>= unify (Named "Bool")
        (bs,l,r,gs,tr) <- walk e m consequence
        pure (bs,l,r,guard:gs,tr)
      walk e m (Invoke n as) = do
        (u,called) <- case M.lookup (unit,n) table of
          Just v -> pure (unit,v)
          Nothing -> maybe (throwC ("unknown law: " ++ n)) (pure . (,) "prelude") (M.lookup ("prelude",n) table)
        expand table u e (key:stack) called (map (subst m) as)
  (bs,l,r,gs,tr) <- walk env replacements (definition law)
  pure (bs,l,r,gs,(lawName law ++ concatMap ((" "++) . prettyExpr) args):tr)

unique :: String -> [String] -> Either String ()
unique kind xs = unless (length xs == length (nub xs)) (Left ("duplicate " ++ kind))
validType :: Type -> Bool
validType (Named n) = n `elem` ["Int32","Text","Bool"]
validType (Variable _) = True
validType (Arrow a b) = validType a && validType b
scalar :: Type -> Bool
scalar (Arrow _ _) = False
scalar t = validType t
validateUnit :: Unit -> Either [Diagnostic] ()
validateUnit u = either (Left . pure . (\m -> Diagnostic "declaration" m Nothing)) Right $ do
  unique "function" (map fst (functions u)); unique "law" (map lawName (laws u))
  forM_ (functions u) $ \(n,t) -> do
    unless (maybe False (isLower . fst) (uncons n)) (Left "function names must start with a lowercase letter")
    case t of
      Arrow a@(Named _) b@(Named _) | validType a && validType b -> pure ()
      _ -> Left (n ++ ": functions require a monomorphic unary Int32/Text/Bool signature")
  forM_ (laws u) $ \l -> do
    mapM_ (metadataText (map fst (parameters l ++ functions u))) [description l, rationale l]
    forM_ (examples l) $ \ex ->
      when (null (expectations ex)) (Left ("example " ++ exampleName ex ++ " requires at least one expect assertion; add expect <expression> = <literal>"))
    unique "parameter" (map fst (parameters l)); unique "example" (map exampleName (examples l))
    forM_ (parameters l) $ \(_,t) -> case t of
      Arrow a b | scalar a && scalar b -> pure ()
      _ -> Left "law parameters must be unary functions between scalar types"
    unless (all scalar (requirements l)) (Left "Eq requires a scalar type")
    unless (all (validType . snd) (parameters l) && all validType (requirements l)) (Left "unsupported type")

compile :: [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compile sources = do
  us <- traverse parseSource (preludeSource:sources)
  unless (length us == length (nub (map unitName us))) (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  mapM_ validateUnit us
  let table = M.fromList [((unitName u,lawName l),l) | u <- us, l <- laws u]
  allExpanded <- forM [(u,l) | u <- us,l <- laws u] $ \(u,l) ->
    either (Left . pure . (\m -> Diagnostic "semantic" m (Just (location l)))) Right $ evalStateT (do
      let symbolic = not (null (parameters l))
          rigid (Variable n) = Named ("@" ++ n)
          rigid (Arrow a b) = Arrow (rigid a) (rigid b)
          rigid t = t
          env = M.fromList ([(n,rigid t) | (n,t) <- parameters l] ++ functions u)
      (bs,a,b,gs,tr) <- expand table (unitName u) env [] l (map (Var . fst) (parameters l))
      checkedInputs <- forM bs $ \v -> do
        t <- resolve (inputType v)
        unless (validType t || (symbolic && case t of Named ('@':_) -> True; _ -> False)) (throwC "unsupported quantified type")
        when (not symbolic && t `notElem` [Named "Int32", Named "Text", Named "Bool"]) (throwC "executable inputs must have type Int32, Text or Bool")
        pure v{inputType=t}
      os <- gets obligations >>= mapM resolve
      allowed <- mapM (resolve . rigid) (requirements l)
      forM_ os $ \t -> unless (t `elem` [Named "Int32",Named "Text",Named "Bool"] || (symbolic && t `elem` allowed)) (throwC ("unsatisfied Eq requirement: " ++ prettyType t))
      unless symbolic $ do
        when (null checkedInputs) (throwC "an executable law must quantify at least one Int32, Text or Bool input")
        lift (unique "expanded input name" (map inputName checkedInputs))
      forM_ (examples l) $ \ex -> withContext ("example " ++ exampleName ex ++ ": ") $ do
        lift (unique "example binding" (map fst (bindings ex)))
        unless (M.keys (M.fromList (bindings ex)) == M.keys (M.fromList [(inputName v,()) | v <- checkedInputs])) (throwC ("example " ++ exampleName ex ++ " must bind exactly: " ++ intercalate ", " (map inputName checkedInputs)))
        forM_ (bindings ex) $ \(n,v) -> do
          actual <- infer M.empty (case v of IntLiteral k -> Number k; TextLiteral text -> StringLit text; BoolLiteral flag -> BoolLit flag)
          case lookup n [(inputName inp,inputType inp) | inp <- checkedInputs] of
            Just expected -> unless (actual == expected) (throwC ("example " ++ exampleName ex ++ ": " ++ n ++ " expects " ++ prettyType expected ++ ", got " ++ prettyType actual))
            Nothing -> throwC "unknown example input"
        let exampleEnv = M.union (M.fromList [(inputName inp,inputType inp) | inp <- checkedInputs]) env
        forM_ (expectations ex) $ \check -> do
          actualType <- infer exampleEnv (actual check) >>= resolve
          expectedType <- infer M.empty (case expected check of IntLiteral k -> Number k; TextLiteral text -> StringLit text; BoolLiteral flag -> BoolLit flag)
          unless (actualType == expectedType) (throwC ("example " ++ exampleName ex ++ ": expectation " ++ prettyExpr (actual check) ++ " has type " ++ prettyType actualType ++ ", expected literal has type " ++ prettyType expectedType))
      pure (Expanded (unitName u) (lawName l) checkedInputs a b gs tr l)
      ) (CS M.empty 0 [])
  pure (filter ((/= "prelude") . unitName) us, filter (null . parameters . original) allExpanded)

prettyExpanded :: Expanded -> String
prettyExpanded e = "for all " ++ intercalate " " ["(" ++ inputName i ++ " :: " ++ prettyType (inputType i) ++ ")" | i <- inputs e] ++ " . " ++ concatMap ((++ " implies ") . showExpr) (guards e) ++ showExpr (left e) ++ " = " ++ showExpr (right e)
  where names = M.fromList [(inputId i,Var (inputName i)) | i <- inputs e]
        showExpr = prettyExpr . subst names

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
