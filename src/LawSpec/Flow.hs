-- Flow typing (Wilshaw & Hutton, "Flow Typing: A New Lens on Linearity"),
-- core form. A signature argument `A / A'` is a flow parameter: a call takes
-- the state at A and leaves it at A'. In a law, `~s` passes the quantified
-- state s to a flow parameter and rebinds s to the state the call leaves;
-- `e1; e2` sequences two expressions. A definition updates its flow
-- parameter with `~s := e`.
--
-- Typestate is checked left to right over each law clause: Γ maps each flow
-- variable to its current type, an index pattern `v` or `v + k` is inverted
-- against it, and the side condition (the current index is at least k) must
-- follow from the quantifiers' lower bounds. Definitions need no separate
-- check: their desugared bodies return the flow product, whose index the
-- ordinary index prover checks.
--
-- Desugaring is A-normal: each flow function f returns a generated product
-- FFlow { result, state } (no result for Unit), and each flow call becomes
-- `match f ... s with | FFlow r s' -> ... end` around the clause side that
-- uses it. The product is indexed by the output state's indices, so an
-- adapter's output index is runtime checked like any indexed result.
module LawSpec.Flow (desugarFlows, flowTypeName) where

import Control.Monad (forM, forM_, unless, when, foldM)
import Control.Monad.State.Strict (StateT, runStateT, get, put, modify, lift)
import Data.Char (toUpper)
import Data.List (intercalate, isInfixOf, nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Indexed (IndexedFamily(..), IndexedConstructor(..), indexedRefinementName)
import LawSpec.Model
import LawSpec.Scalar (Scalar(..))

type Failure = (Maybe Location, String)

-- The parser's spelling of `A / A'`; it never survives desugaring.
flowTypeName :: String
flowTypeName = "Flow#"

data FlowSignature = FlowSignature
  { flowName :: String
  , flowArguments :: [Type]
  -- Each flow parameter, in argument order.
  , flowParameters :: [FlowParameter]
  , flowResult :: Type
  , flowProduct :: String
  }

-- A flow parameter A / A': its argument position, and the state's type
-- before and after the call.
data FlowParameter = FlowParameter
  { parameterPosition :: Int
  , parameterInput :: Type
  , parameterOutput :: Type
  }

flowPositions :: FlowSignature -> [Int]
flowPositions = map parameterPosition . flowParameters

-- The product's field for each state: state, or state1, state2, ... when a
-- function has several.
stateFields :: FlowSignature -> [String]
stateFields s = case flowParameters s of
  [_] -> ["state"]
  ps -> ["state" ++ show k | (k, _) <- zip [1 :: Int ..] ps]

-- Desugar a unit's flow signatures, law clauses and definitions; the new
-- products join the unit's indexed families (or plain data types).
desugarFlows :: [IndexedFamily] -> [IndexedFamily] -> Unit -> Either Failure ([IndexedFamily], Unit)
desugarFlows imported families u
  | not (usesFlow u) = pure (families, u)
  | otherwise = do
      let table = M.fromList [(familyName f, f) | f <- imported ++ families]
          definitionSignatures = [(functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))) | d <- functionDefinitions u]
      -- A definition's signature is also among the unit's functions.
      signatures <- fmap concat $ forM (M.toList (M.fromList (functions u ++ definitionSignatures))) $ \(name, ty) ->
        maybe [] pure <$> flowSignature name ty
      let flows = M.fromList [(flowName s, s) | s <- signatures]
          taken = map dataTypeName (dataTypes u) ++ map familyName (imported ++ families)
      forM_' signatures $ \s -> when (flowProduct s `elem` taken)
        (Left (Nothing, "flow product " ++ flowProduct s ++ " of " ++ flowName s ++ " clashes with a declared type"))
      products <- mapM (flowProductType table) signatures
      let newFamilies = [f | Left f <- products]
          newTypes = [d | Right d <- products]
      functions' <- forM (functions u) $ \(name, ty) -> case M.lookup name flows of
        Just s -> (,) name <$> productSignature table s
        Nothing -> pure (name, ty)
      lawResults <- mapM (flowLaw table flows) (laws u)
      definitionResults <- mapM (flowDefinition table flows) (functionDefinitions u)
      let laws' = map fst lawResults
          definitions' = map fst definitionResults
          arities = S.toList (S.unions (map snd lawResults ++ map snd definitionResults))
          joins = [joinType k | k <- arities]
      forM_' joins $ \j -> when (dataTypeName j `elem` taken)
        (Left (Nothing, "the generated type " ++ dataTypeName j ++ " clashes with a declared type"))
      let u' = u { functions = functions', laws = laws', functionDefinitions = definitions', dataTypes = dataTypes u ++ newTypes ++ joins }
          leftover = show (functions u', laws u', functionDefinitions u', contracts u', refinements u')
      when ("Var \"~" `isInfixOf` leftover)
        (Left (Nothing, "~s is allowed only as an argument to a flow parameter, in a law or definition"))
      when ("Binary \";\"" `isInfixOf` leftover || "Binary \":=\"" `isInfixOf` leftover)
        (Left (Nothing, "; and := may appear only in a law clause or a definition body"))
      when (("Application " ++ show flowTypeName) `isInfixOf` leftover)
        (Left (Nothing, "a flow type A / A' is legal only as a signature argument"))
      pure (families ++ newFamilies, u')

-- A branch join: a branch's value and the states it leaves.
joinType :: Int -> DataTypeDeclaration
joinType k =
  let origin = Span (Location "<flow>" 0 0) (Location "<flow>" 0 0)
      name = "FlowJoin" ++ show k
      variables = ["a" ++ show i | i <- [1 .. k]]
  in DataTypeDeclaration name variables
       [ConstructorDeclaration name [("field" ++ show i, Variable v) | (i, v) <- zip [1 :: Int ..] variables] origin []] origin Nothing

forM_' :: [a] -> (a -> Either Failure ()) -> Either Failure ()
forM_' xs f = mapM_ f xs

usesFlow :: Unit -> Bool
usesFlow u = any (`isInfixOf` text) [show flowTypeName, "Var \"~", "Binary \";\"", "Binary \":=\""]
  where text = show (functions u, laws u, functionDefinitions u)

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

arguments :: Type -> ([Type], Type)
arguments (Arrow a b) = let (as, r) = arguments b in (a : as, r)
arguments t = ([], t)

unrefined :: Type -> Type
unrefined (Refined _ t _) = unrefined t
unrefined t = t

isFlow :: Type -> Maybe (Type, Type)
isFlow (Application n [a, b]) | n == flowTypeName = Just (a, b)
isFlow _ = Nothing

flowSignature :: String -> Type -> Either Failure (Maybe FlowSignature)
flowSignature name ty = do
  let (args, result) = arguments ty
      positions = [(i, a, b) | (i, arg) <- zip [0 ..] args, Just (a, b) <- [isFlow arg]]
  case positions of
    [] -> pure Nothing
    _ -> do
      when (show flowTypeName `isInfixOf` show (unrefined result))
        (Left (Nothing, name ++ ": a flow type A / A' is legal only as an argument"))
      pure (Just (FlowSignature name args [FlowParameter i a b | (i, a, b) <- positions] result (capitalize name ++ "Flow")))

-- A state type's head family and its arguments.
stateShape :: Type -> Maybe (String, [RefinementArgument])
stateShape ty = case unrefined ty of
  RefinementApp n args | Just family <- stripIndex n -> Just (family, args)
  _ -> Nothing
  where
    stripIndex n = let suffix = indexedRefinementName "" in
      if suffix `isSuffix` n then Just (take (length n - length suffix) n) else Nothing
    isSuffix s n = reverse s == take (length s) (reverse n)

typeVariables :: Type -> [String]
typeVariables ty = case ty of
  Variable v -> [v]
  Arrow a b -> typeVariables a ++ typeVariables b
  Applied _ t -> typeVariables t
  Application _ ts -> concatMap typeVariables ts
  Refined _ t _ -> typeVariables t
  RefinementApp _ args -> concat [typeVariables t | TypeArgument t <- args]
  Qualified _ t -> typeVariables t
  CheckedType _ t -> typeVariables t
  _ -> []

isUnit :: Type -> Bool
isUnit t = case unrefined t of
  Named "Unit" -> True
  _ -> False

-- The product a flow function returns: indexed by the output state's
-- indices, generic in the type variables of the result and state.
flowProductType :: M.Map String IndexedFamily -> FlowSignature -> Either Failure (Either IndexedFamily DataTypeDeclaration)
flowProductType _ s = do
  let outputs = [unrefined (parameterOutput p) | p <- flowParameters s]
      result = unrefined (flowResult s)
      variables = nub (typeVariables result ++ concatMap typeVariables outputs)
      resultField = [("result", result) | not (isUnit result)]
      origin = Span (Location "<flow>" 0 0) (Location "<flow>" 0 0)
      single = length outputs == 1
      -- Each indexed state's index variables, named per state when there
      -- are several (i0, or i1_0, i2_0, ...).
      indexName k i = if single then "i" ++ show i else "i" ++ show k ++ "_" ++ show i
      boundName k i = if single then "m" ++ show i else "m" ++ show k ++ "_" ++ show i
      stateField (k, output) = case stateShape output of
        Just (family, args) ->
          ( [(indexName k i, boundName k i) | (i, ValueArgument _) <- zip [0 :: Int ..] args]
          , RefinementApp (indexedRefinementName family)
              [case arg of
                 ValueArgument _ -> ValueArgument (Var (boundName k i))
                 TypeArgument t -> TypeArgument t
              | (i, arg) <- zip [0 :: Int ..] args] )
        Nothing -> ([], output)
      fields = map stateField (zip [1 :: Int ..] outputs)
      names = concatMap fst fields
      constructor = ConstructorDeclaration (flowProduct s) (resultField ++ zip (stateFields s) (map snd fields)) origin []
  if any ((/= Nothing) . stateShape) outputs
    then pure (Left (IndexedFamily (flowProduct s)
      ([(i, False) | (i, _) <- names] ++ [(v, True) | v <- variables])
      [IndexedConstructor constructor [(i, Var m) | (i, m) <- names]] origin))
    else pure (Right (DataTypeDeclaration (flowProduct s) variables [constructor] origin Nothing))

-- The product type a call returns, at the output state's arguments.
productType :: FlowSignature -> Type
productType s =
  let outputs = [unrefined (parameterOutput p) | p <- flowParameters s]
      variables = nub (typeVariables (unrefined (flowResult s)) ++ concatMap typeVariables outputs)
      shapes = [shape | Just shape <- map stateShape outputs]
  in if not (null shapes)
    then RefinementApp (indexedRefinementName (flowProduct s))
      ([ValueArgument e | (_, args) <- shapes, ValueArgument e <- args] ++ [TypeArgument (Variable v) | v <- variables])
    else case variables of
      [] -> Named (flowProduct s)
      [v] -> Applied (flowProduct s) (Variable v)
      vs -> Application (flowProduct s) (map Variable vs)

-- The state-passing signature: the flow argument takes the input state and
-- the result is the product.
productSignature :: M.Map String IndexedFamily -> FlowSignature -> Either Failure Type
productSignature _ s =
  pure (foldr Arrow (productType s)
    [maybe a parameterInput (lookup i [(parameterPosition p, p) | p <- flowParameters s]) | (i, a) <- zip [0 ..] (flowArguments s)])

-- Linear natural index terms: coefficients by variable, and a constant.
data Linear = Linear (M.Map String Integer) Integer deriving (Eq, Show)

linear :: Expr -> Maybe Linear
linear e = case unlocated e of
  Number n | n >= 0 -> Just (Linear M.empty n)
  Var v -> Just (Linear (M.singleton v 1) 0)
  Binary "+" a b -> add <$> linear a <*> linear b
  Binary "*" a b -> case (unlocated a, unlocated b) of
    (Number k, _) -> scale k <$> linear b
    (_, Number k) -> scale k <$> linear a
    _ -> Nothing
  _ -> Nothing
  where
    add (Linear xs c) (Linear ys d) = Linear (M.filter (/= 0) (M.unionWith (+) xs ys)) (c + d)
    scale k (Linear xs c) = Linear (M.filter (/= 0) (M.map (* k) xs)) (k * c)

render :: Linear -> Expr
render (Linear xs c) = case [term v k | (v, k) <- M.toList xs] ++ [Number c | c /= 0 || M.null xs] of
  [] -> Number 0
  t : ts -> foldl (Binary "+") t ts
  where term v 1 = Var v
        term v k = Binary "*" (Number k) (Var v)

minus :: Linear -> Integer -> Linear
minus (Linear xs c) k = Linear xs (c - k)

substituteLinear :: M.Map String Linear -> Linear -> Linear
substituteLinear σ (Linear xs c) = M.foldrWithKey step (Linear M.empty c) xs
  where
    step v k (Linear acc d) = case M.lookup v σ of
      Just (Linear ys e) -> Linear (M.filter (/= 0) (M.unionWith (+) acc (M.map (* k) ys))) (d + k * e)
      Nothing -> Linear (M.filter (/= 0) (M.insertWith (+) v k acc)) d

-- The flow environment: each variable's current state type and the
-- expression that now stands for it. `checked` is False in definitions,
-- whose desugared bodies inference and the index prover check instead.
data Flow = Flow
  { flowStates :: M.Map String (Type, Expr)
  , flowFacts :: M.Map String Integer
  , flowFresh :: Int
  , flowChecked :: Bool
  -- States whose branches left them at different types: using one again is
  -- an error, with this message.
  , flowPoisoned :: M.Map String String
  -- The arities of the branch joins (FlowJoinN) the desugaring used.
  , flowJoins :: S.Set Int
  }

type Binding = (Expr, String, [String])
type F = StateT Flow (Either Failure)

failAt :: Maybe Location -> String -> F a
failAt at message = lift (Left (at, message))

-- Lower bounds `v >= k` and `v > k` from quantifier refinements.
facts :: [(String, Type)] -> M.Map String Integer
facts params = M.fromListWith max (concatMap (bounds . snd) params)
  where
    bounds ty = case ty of
      Refined _ t (Just e) -> conjuncts e ++ bounds t
      Refined _ t Nothing -> bounds t
      _ -> []
    conjuncts e = case unlocated e of
      Binary "&&" a b -> conjuncts a ++ conjuncts b
      Binary ">=" a b | Var v <- unlocated a, Number k <- unlocated b -> [(v, k)]
      Binary ">" a b | Var v <- unlocated a, Number k <- unlocated b -> [(v, k + 1)]
      _ -> []

-- The least value of a natural linear term, given lower bounds.
lowerBound :: M.Map String Integer -> Linear -> Integer
lowerBound bounds (Linear xs c) = c + sum [k * M.findWithDefault 0 v bounds | (v, k) <- M.toList xs]

bindAll :: [(String, Type)] -> M.Map String (Type, Expr)
bindAll params = M.fromList [(n, (t, Var n)) | (n, t) <- params]

flowLaw :: M.Map String IndexedFamily -> M.Map String FlowSignature -> Law -> Either Failure (Law, S.Set Int)
flowLaw _ flows law = do
  let at = Just (location law)
      start = Flow (bindAll (parameters law)) (facts (parameters law)) 0 True M.empty S.empty
  (d, end) <- runStateT (proposition at flows (definition law)) start
  pure (law { definition = d }, flowJoins end)

proposition :: Maybe Location -> M.Map String FlowSignature -> Definition -> F Definition
proposition at flows d = case d of
  Forall params body -> do
    modify (\f -> f { flowStates = M.union (bindAll params) (flowStates f)
                    , flowFacts = M.unionWith max (facts params) (flowFacts f) })
    Forall params <$> proposition at flows body
  Equal a b -> do
    (left, bindingsA) <- rewrite at flows True a
    (right, bindingsB) <- rewrite at flows True b
    -- Each side repeats the calls before it, so both see the same states.
    pure (Equal (wrap bindingsA left) (wrap (bindingsA ++ bindingsB) right))
  Holds e -> do
    (value, bindings) <- rewrite at flows True e
    pure (Holds (wrap bindings value))
  Implies guard body -> do
    (value, bindings) <- rewrite at flows True guard
    unless (null bindings)
      (failAt at "an implication's guard cannot call a flow function; state the call in the conclusion")
    Implies value <$> proposition at flows body
  And a b -> do
    saved <- get
    a' <- proposition at flows a
    put saved
    b' <- proposition at flows b
    put saved
    pure (And a' b')
  Invoke n es -> do
    es' <- mapM (\e -> do (v, bs) <- rewrite at flows True e; pure (wrap bs v)) es
    pure (Invoke n es')

wrap :: [Binding] -> Expr -> Expr
wrap bindings body = foldr (\(call, tag, names) inner -> MatchExpr call [MatchBranch tag names inner]) body bindings

fresh :: String -> F String
fresh base = do
  f <- get
  put f { flowFresh = flowFresh f + 1 }
  pure (base ++ "_flow" ++ show (flowFresh f))

-- Left-to-right rewriting. `sequential` is False inside branches and the
-- right operands of && and ||, where a flow call could not leave its state.
rewrite :: Maybe Location -> M.Map String FlowSignature -> Bool -> Expr -> F (Expr, [Binding])
rewrite at flows sequential expression = case expression of
  Located range e -> do
    (e', bs) <- rewrite (Just (spanStart range)) flows sequential e
    pure (Located range e', bs)
  Binary ";" a b -> do
    (_, as) <- rewrite at flows sequential a
    (b', bs) <- rewrite at flows sequential b
    pure (b', as ++ bs)
  Binary ":=" _ _ -> failAt at "~s := e may appear only in a definition with flow parameter s"
  Binary op a b | op `elem` ["&&", "||"] -> do
    (a', as) <- rewrite at flows sequential a
    (b', bs) <- rewrite at flows False b
    pure (Binary op a' (wrap bs b'), as)
  Var ('~' : name) -> failAt at ("~" ++ name ++ " is passed to something that does not take a flow parameter")
  Var v -> do
    poisoned <- flowPoisoned <$> get
    maybe (pure ()) (failAt at) (M.lookup v poisoned)
    states <- flowStates <$> get
    pure (maybe (Var v) snd (M.lookup v states), [])
  -- if c then a else b (prelude.select): its branches may call flow
  -- functions, as a match's may.
  Apply _ _ | (Var "prelude.select", [c, a, b]) <- spine expression -> do
    (c', cs) <- rewrite at flows sequential c
    (value, bindings) <- branching at flows sequential
      [("then", [], a), ("else", [], b)]
      (\bodies -> foldl Apply (Var "prelude.select") (c' : bodies))
    pure (value, cs ++ bindings)
  Apply _ _ | (Var f, args) <- spine expression, Just s <- M.lookup f flows -> do
    unless sequential (failAt at ("the flow call " ++ f ++ " cannot appear after && / || or in an all-elements predicate, where it may not run; sequence it before"))
    unless (length args == length (flowArguments s))
      (failAt at (f ++ " takes " ++ show (length (flowArguments s)) ++ " arguments"))
    let positions = flowPositions s
    (args', bindings) <- foldM (\(done, bs) (i, arg) ->
      if i `elem` positions then pure (done ++ [arg], bs) else do
        (arg', bs') <- rewrite at flows sequential arg
        pure (done ++ [arg'], bs ++ bs')) ([], []) (zip [0 ..] args)
    variables <- forM positions $ \i -> case unlocated (args' !! i) of
      Var ('~' : name) -> pure name
      _ -> failAt at (f ++ " takes a flow parameter here: write ~s for a state s")
    unless (length (nub variables) == length variables)
      (failAt at (f ++ " is given the same state twice; each flow parameter takes its own state"))
    poisoned <- flowPoisoned <$> get
    forM_ variables $ \v -> maybe (pure ()) (failAt at) (M.lookup v poisoned)
    states <- flowStates <$> get
    currents <- forM variables $ \v -> maybe (failAt at ("~" ++ v ++ " is not a quantified variable or parameter")) pure
      (M.lookup v states)
    checked <- flowChecked <$> get
    let others = [(t, a) | (i, t, a) <- zip3 [0 ..] (flowArguments s) args', i `notElem` positions]
    nexts <- forM (zip (flowParameters s) currents) $ \(parameter, (current, _)) ->
      if checked then transition at f parameter current others else pure current
    stateNames <- mapM fresh variables
    resultName <- fresh "result"
    let values = M.fromList (zip positions (map snd currents))
        call = foldl Apply (Var f) [M.findWithDefault a i values | (i, a) <- zip [0 :: Int ..] args']
        unitResult = isUnit (flowResult s)
        names = [resultName | not unitResult] ++ stateNames
    modify (\st -> st { flowStates = foldr (\(v, (next, n)) -> M.insert v (next, Var n)) (flowStates st)
                                        (zip variables (zip nexts stateNames)) })
    pure (if unitResult then ScalarLit (SAbsent "Unit") else Var resultName, bindings ++ [(call, flowProduct s, names)])
  Apply a b -> two Apply a b
  Compose a b -> two Compose a b
  Binary op a b -> two (Binary op) a b
  Unary op a -> do (a', as) <- rewrite at flows sequential a; pure (Unary op a', as)
  Annotate a t -> do (a', as) <- rewrite at flows sequential a; pure (Annotate a' t, as)
  ListLit es -> do
    results <- mapM (rewrite at flows sequential) es
    pure (ListLit (map fst results), concatMap snd results)
  ConstructLit n es -> do
    results <- mapM (rewrite at flows sequential) es
    pure (ConstructLit n (map fst results), concatMap snd results)
  MatchExpr value branches -> do
    (value', vs) <- rewrite at flows sequential value
    (result, bindings) <- branching at flows sequential
      [(lastSegment tag, names, body) | MatchBranch tag names body <- branches]
      (\bodies -> MatchExpr value' [MatchBranch tag names body | (MatchBranch tag names _, body) <- zip branches bodies])
    pure (result, vs ++ bindings)
  AllElementsExpr xs n p -> do
    (xs', bs) <- rewrite at flows sequential xs
    p' <- shadowed [n] (rewrite at flows False p)
    pure (AllElementsExpr xs' n p', bs)
  _ -> pure (expression, [])
  where
    two k a b = do
      (a', as) <- rewrite at flows sequential a
      (b', bs) <- rewrite at flows sequential b
      pure (k a' b', as ++ bs)
    shadowed :: [String] -> F (Expr, [Binding]) -> F Expr
    shadowed names inner = do
      saved <- get
      modify (\f -> f { flowStates = foldr M.delete (flowStates f) names })
      (body, bs) <- inner
      put saved
      pure (wrap bs body)

-- The branches of a match or an if. Without flow calls in them, each branch
-- keeps its own bindings. With some, the whole branching becomes one
-- binding: every branch returns its value and the states it leaves in a
-- FlowJoinN, and the states are rebound to the join's fields after it. A
-- state the branches leave at different types cannot be used afterwards.
branching :: Maybe Location -> M.Map String FlowSignature -> Bool -> [(String, [String], Expr)]
          -> ([Expr] -> Expr) -> F (Expr, [Binding])
branching at flows sequential branches rebuild = do
  saved <- get
  results <- forM branches $ \(label, names, body) -> do
    current <- get
    put saved { flowStates = foldr M.delete (flowStates saved) names, flowFresh = flowFresh current, flowJoins = flowJoins current }
    (body', bs) <- rewrite at flows sequential body
    after <- get
    pure (label, names, body', bs, after)
  final <- get
  put saved { flowFresh = flowFresh final, flowJoins = flowJoins final }
  if all (\(_, _, _, bs, _) -> null bs) results
    then pure (rebuild [body | (_, _, body, _, _) <- results], [])
    else do
      let original v = M.lookup v (flowStates saved)
          leaves v (_, _, _, _, after) = maybe (original v) Just (M.lookup v (flowStates after))
          moved v r = fmap (show . snd) (leaves v r) /= fmap (show . snd) (original v)
          changed = [v | v <- M.keys (flowStates saved), any (moved v) results]
      checked <- flowChecked <$> get
      forM_ changed $ \v -> do
        let types = [(label, maybe "" (showType . fst) (leaves v r)) | r@(label, _, _, _, _) <- results]
        when (checked && length (nub (map snd types)) > 1) $ modify (\st -> st { flowPoisoned = M.insert v
          ("after these branches, " ++ v ++ " is " ++ intercalate ", but " [t ++ " in the " ++ label ++ " branch" | (label, t) <- types] ++
           "; use " ++ v ++ " only inside the branches, or bring every branch to the same state") (flowPoisoned st) })
      let arity = 1 + length changed
          join = "FlowJoin" ++ show arity
      resultName <- fresh "branch"
      newNames <- mapM fresh changed
      let body (_, _, body', bs, after) = wrap bs (ConstructLit join (body' :
            [maybe (Var v) snd (maybe (original v) Just (M.lookup v (flowStates after))) | v <- changed]))
          firstType v = case results of
            r : _ -> maybe (Named "Unit") fst (leaves v r)
            [] -> Named "Unit"
      modify (\st -> st { flowJoins = S.insert arity (flowJoins st)
                         , flowStates = foldr (\(v, n) -> M.insert v (firstType v, Var n)) (flowStates st) (zip changed newNames) })
      unless sequential (failAt at "a branch calls a flow function where it may not run (after && / ||); sequence it before")
      pure (Var resultName, [(rebuild (map body results), join, resultName : newNames)])

lastSegment :: String -> String
lastSegment n = case break (== ':') n of
  (_, ':' : ':' : rest) -> lastSegment rest
  (whole, _) -> whole

spine :: Expr -> (Expr, [Expr])
spine e = case unlocated e of
  Apply f a -> let (h, as) = spine f in (h, as ++ [a])
  other -> (other, [])

-- Check a flow call against the current state type and return the state it
-- leaves: invert the input pattern, prove its side condition, substitute.
transition :: Maybe Location -> String -> FlowParameter -> Type -> [(Type, Expr)] -> F Type
transition at f s current others = do
  let pattern = unrefined (parameterInput s)
      state = unrefined current
  bounds <- flowFacts <$> get
  -- A dependent value argument fixes its index variable, when it is linear.
  let fixed = M.fromList [(n, maybe (Linear (M.singleton ('?' : n) 1) 0) id (linear a)) | (Refined n _ _, a) <- others]
  (indices, types) <- case (stateShape pattern, stateShape state) of
    (Just (family, patterns), Just (family', actuals)) | family == family', length patterns == length actuals ->
      foldM (\(σ, τ) (p, a) -> case (p, a) of
        (ValueArgument pe, ValueArgument ae) -> do
          pl <- maybe (failAt at (f ++ ": a flow index pattern must be linear")) pure (linear pe)
          al <- maybe (failAt at (f ++ ": the state index of " ++ showType current ++ " is not linear")) pure (linear ae)
          σ' <- invert bounds σ pl al
          pure (σ', τ)
        (TypeArgument pt, TypeArgument t) -> pure (σ, bindType τ pt t)
        _ -> failAt at (f ++ ": mismatched state arguments")) (fixed, M.empty) (zip patterns actuals)
    (Nothing, Nothing) | showType pattern == showType state || not (null (typeVariables pattern)) ->
      pure (fixed, bindType M.empty pattern state)
    _ -> failAt at (f ++ " needs " ++ showType pattern ++ "; the state is " ++ showType current)
  substituteState at f indices types (unrefined (parameterOutput s))
  where
    invert bounds σ pl@(Linear pxs k) al = case M.toList pxs of
      [] -> do
        unless (al == pl) (failAt at (f ++ " needs " ++ showType (unrefined (parameterInput s)) ++ "; the state is " ++ showType current))
        pure σ
      [(v, 1)] -> do
        let rest = minus al k
        case M.lookup v σ of
          Just previous | previous /= rest -> failAt at (f ++ ": the state's indices disagree")
          _ -> pure ()
        when (lowerBound bounds al < k)
          (failAt at (f ++ " needs " ++ showType (unrefined (parameterInput s)) ++ "; the state is " ++ showType current ++
            "; add `where " ++ showExpr (render al) ++ " >= " ++ show k ++
            "` to a quantifier, or quantify the state at an index of the form m + " ++ show k))
        pure (M.insert v rest σ)
      _ -> failAt at (f ++ ": a flow index pattern must be v or v + k")
    bindType τ (Variable v) actual = M.insert v actual τ
    bindType τ (Applied _ p) (Applied _ a) = bindType τ p a
    bindType τ (Application _ ps) (Application _ as) = foldl (\acc (p, a) -> bindType acc p a) τ (zip ps as)
    bindType τ _ _ = τ

substituteState :: Maybe Location -> String -> M.Map String Linear -> M.Map String Type -> Type -> F Type
substituteState at f indices types ty = case ty of
  RefinementApp n args -> RefinementApp n <$> mapM argument args
  Variable v -> pure (M.findWithDefault ty v types)
  Applied n t -> Applied n <$> substituteState at f indices types t
  Application n ts -> Application n <$> mapM (substituteState at f indices types) ts
  _ -> pure ty
  where
    argument (TypeArgument t) = TypeArgument <$> substituteState at f indices types t
    argument (ValueArgument e) = case linear e of
      Just l -> do
        let l'@(Linear xs _) = substituteLinear indices l
        when (any (\v -> take 1 v == "?") (M.keys xs))
          (failAt at (f ++ ": the state's index depends on an argument that is not a number or variable"))
        pure (ValueArgument (render l'))
      Nothing -> failAt at (f ++ ": the output state index must be linear")

showType :: Type -> String
showType ty = case ty of
  Named n -> n
  Variable v -> v
  Applied n t -> n ++ " " ++ atom t
  Application n ts -> unwords (n : map atom ts)
  RefinementApp n args -> unwords (takeWhile (/= '@') n : map argument args)
  Refined _ t _ -> showType t
  _ -> show ty
  where
    atom t = let s = showType t in if ' ' `elem` s then "(" ++ s ++ ")" else s
    argument (TypeArgument t) = atom t
    argument (ValueArgument e) = let s = showExpr e in if ' ' `elem` s then "(" ++ s ++ ")" else s

showExpr :: Expr -> String
showExpr e = case unlocated e of
  Number n -> show n
  Var v -> v
  Binary op a b -> showExpr a ++ " " ++ op ++ " " ++ showExpr b
  other -> show other

-- A definition's flow parameter: `~s := e` updates it, and the body returns
-- the product of the final result and state. Calls to other flow functions
-- thread states as in laws. Inference and the index prover check the
-- desugared body, so there is no separate typestate check here.
flowDefinition :: M.Map String IndexedFamily -> M.Map String FlowSignature -> FunctionDefinition -> Either Failure (FunctionDefinition, S.Set Int)
flowDefinition _ flows d = case M.lookup (functionName d) flows of
  Nothing
    | uses -> run (do
        (body, bindings) <- statements [] (functionBody d)
        pure d { functionBody = wrap bindings body })
    | otherwise -> pure (d, S.empty)
  Just s -> do
    let inputs = M.fromList [(parameterPosition p, parameterInput p) | p <- flowParameters s]
        stateNames = [fst (functionArguments d !! i) | i <- flowPositions s]
        arguments' = [(n, M.findWithDefault t i inputs) | (i, (n, t)) <- zip [0 :: Int ..] (functionArguments d)]
    run (do
      (body, bindings) <- statements stateNames (functionBody d)
      states <- flowStates <$> get
      let finals = [maybe (Var n) snd (M.lookup n states) | n <- stateNames]
          resultPart = [body | not (isUnit (flowResult s))]
      pure d { functionArguments = arguments', functionResult = productType s
             , functionBody = wrap bindings (ConstructLit (flowProduct s) (resultPart ++ finals)) })
  where
    at = Just (spanStart (functionSpan d))
    uses = any (`isInfixOf` show (functionBody d)) ["Var \"~", "Binary \";\"", "Binary \":=\""]
    start = Flow (bindAll (functionArguments d)) M.empty 0 False M.empty S.empty
    run action = (\(value, end) -> (value, flowJoins end)) <$> runStateT action start
    statements owned e = case unlocated e of
      Binary ";" a b -> do
        (_, as) <- statements owned a
        (b', bs) <- statements owned b
        pure (b', as ++ bs)
      Binary ":=" target value -> case unlocated target of
        Var ('~' : name) | name `elem` owned -> do
          (value', vs) <- rewrite at flows True value
          modify (\f -> f { flowStates = M.adjust (\(t, _) -> (t, value')) name (flowStates f) })
          pure (ScalarLit (SAbsent "Unit"), vs)
        _ -> lift (Left (at, "~s := e updates only one of the definition's own flow parameters"))
      _ -> rewrite at flows True e
