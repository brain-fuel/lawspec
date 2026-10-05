-- Stateful models: `model name :: [shared] S by M is ... end` pairs a
-- system's commands with reference definitions over an abstract model state
-- M. This module checks a declaration against the unit's signatures and
-- definitions and elaborates it to a Machine, which LawSpec's model runtimes
-- run. It runs before flow types are desugared, so commands still have their
-- flow parameters and typestate is read from them.
module LawSpec.StatefulModel
  ( ModelDeclaration(..), ModelCommand(..), elaborateModels
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toUpper)
import Data.List (nub)
import LawSpec.Common (Span(..))
import LawSpec.Core.Machine
import LawSpec.Flow (flowTypeName)
import LawSpec.Indexed (indexedRefinementName)
import LawSpec.Model
import LawSpec.Scalar (isInteger)

data ModelDeclaration = ModelDeclaration
  { modelName :: String
  , modelShared :: Bool
  , modelState :: Type
  , modelBy :: Type
  -- The start command, and the model state for its arguments: an
  -- expression for a start taking Unit, or a definition taking the same
  -- arguments.
  , modelStart :: Maybe (String, Expr)
  , modelCommands :: [ModelCommand]
  , modelAbstract :: Maybe String
  , modelInvariants :: [String]
  , modelSpan :: Span
  -- `behaves like C`: modelBy is the built-in collection type C, and each
  -- command names the collection operation it implements.
  , modelBehaves :: Bool
  } deriving (Eq, Show)

data ModelCommand = ModelCommand
  { modelCommand :: String, modelReference :: String, modelWhen :: Maybe String
  -- Whether modelReference names a collection operation (`as`) rather than
  -- a reference definition (`by`).
  , modelAs :: Bool
  } deriving (Eq, Show)

type Failure = (Maybe Span, String)

-- Each model's checks, its machine, and a generated definition of its start
-- state.
elaborateModels :: [ModelDeclaration] -> Unit -> Either Failure Unit
elaborateModels [] u = pure u
elaborateModels declarations u = do
  let names = map modelName declarations
  forM_ declarations $ \m -> when (length (filter (== modelName m) names) > 1)
    (Left (Just (modelSpan m), "model " ++ modelName m ++ " is declared twice"))
  expanded <- forM declarations (behaviour u)
  let behaviours = concat [ds | (_, ds, _) <- expanded]
      signatureOf d = (functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d)))
      u' = u { functionDefinitions = functionDefinitions u ++ behaviours, functions = functions u ++ map signatureOf behaviours }
  results <- forM [(m, keys) | (m, _, keys) <- expanded] $ \(m, keys) -> do
    (machine, start) <- elaborateModel u' m
    let keyed = [c { commandKey = maybe Nothing id (lookup (commandName c) keys) } | c <- machineCommands machine]
        perKey = modelBehaves m && not (null keyed) && all ((/= Nothing) . commandKey) keyed
    pure (machine { machineCommands = keyed, machinePerKey = perKey }, start)
  -- Generated names (start states and the bridges that call adapters) must
  -- not clash with declared ones.
  let taken = map fst (functions u)
  forM_ (zip declarations results) $ \(m, (machine, start)) ->
    forM_ (generatedNames machine ++ maybe [] (pure . functionName) start) $ \n -> when (n `elem` taken)
      (Left (Just (modelSpan m), "model " ++ modelName m ++ " generates " ++ n ++ ", which is already declared; rename one"))
  let starts = [d | (_, Just d) <- results] ++ behaviours
      signature d = (functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d)))
  pure u
    { machines = machines u ++ map fst results
    , functionDefinitions = functionDefinitions u ++ starts
    , functions = functions u ++ map signature starts
    , declarationSpans = declarationSpans u ++ [(functionName d, functionSpan d) | d <- starts] }

elaborateModel :: Unit -> ModelDeclaration -> Either Failure (Machine String, Maybe FunctionDefinition)
elaborateModel u m = do
  let failing message = Left (Just (modelSpan m), "model " ++ modelName m ++ ": " ++ message)
      signatureOf f = lookup f (functions u)
      definitionOf f = [d | d <- functionDefinitions u, functionName d == f]
      definitionType f = case definitionOf f of
        [d] -> Just (foldr Arrow (functionResult d) (map snd (functionArguments d)))
        _ -> Nothing
      modelType = modelBy m
  (family, stateIndices) <- maybe (failing ("its state type " ++ prettyType (modelState m) ++ " is not a declared type")) pure
    (stateHead (modelState m))
  when (modelShared m && not (null stateIndices))
    (failing ("a shared state's type cannot change, so " ++ family ++ " cannot be indexed; use a linear model for typestate"))
  indexVariables <- forM stateIndices $ \index -> case pattern index of
    Just (Left v) -> pure v
    _ -> failing ("its state type must name each index with a variable, as in " ++ family ++ " n")
  unless (length (nub indexVariables) == length indexVariables)
    (failing "its state type's indices must be distinct variables")
  -- A reference definition must be a checked definition of exactly the
  -- expected type.
  let reference what f expected = case definitionType f of
        Nothing -> failing (what ++ " " ++ f ++ " must be a checked definition")
        Just actual -> unless (shape actual == shape expected)
          (failing (what ++ " " ++ f ++ " must have type " ++ prettyType expected ++ ", not " ++ prettyType actual))
      isState t = maybe False ((== family) . fst) (stateHead t)
  commands <- forM (modelCommands m) $ \c -> do
    let name = modelCommand c
        context message = failing ("command " ++ name ++ " " ++ message)
    ty <- maybe (context "has no signature") pure (signatureOf name)
    when (name `elem` map functionName (functionDefinitions u))
      (context "is a checked definition; commands are adapters, the system under test")
    let (args, result) = arguments ty
    (position, needs, shifts) <- if modelShared m
      then case [i | (i, a) <- zip [0 ..] args, isState a] of
        [i] -> pure (i, [], [])
        [] -> context ("must take the shared " ++ family ++ " as an argument")
        _ -> context ("takes " ++ family ++ " more than once")
      else case [(i, a, b) | (i, arg) <- zip [0 ..] args, Just (a, b) <- [flowOf arg]] of
        [(i, a, b)] -> do
          unless (isState a && isState b) (context ("must take the state as a flow parameter " ++ family ++ " ... / " ++ family ++ " ..."))
          (ns, ss) <- typestate (\message -> (Just (modelSpan m), "model " ++ modelName m ++ ": command " ++ name ++ " changes the state's index " ++ message)) indexVariables a b
          pure (i, ns, ss)
        _ -> context ("must take the state as a flow parameter, as in " ++ family ++ " n / " ++ family ++ " (n + 1)")
    let others = [a | (i, a) <- zip [0 :: Int ..] args, i /= position]
    forM_ others $ \a -> when (any (`elem` indexVariables) (typeVariablesOf a) || mentions indexVariables a)
      (context "has an argument whose type depends on the state's index; 0.19 generates arguments independently")
    let unit = isUnitType result
        expected = foldr Arrow (if unit then modelType else Application "Pair" [result, modelType]) (others ++ [modelType])
    reference ("command " ++ name ++ "'s reference") (modelReference c) expected
    forM_ (modelWhen c) $ \p -> reference ("command " ++ name ++ "'s precondition") p (Arrow modelType (Named "Bool"))
    pure (Command name name (bridge ("Run" ++ capitalize name)) (modelReference c) (modelWhen c)
      [i | (i, _) <- zip [0 ..] args, i /= position] position unit needs shifts Nothing)
  forM_ (modelAbstract m) $ \f -> do
    ty <- maybe (failing ("abstract " ++ f ++ " has no signature")) pure (signatureOf f)
    case arguments ty of
      ([s], r) | isState s && shape r == shape modelType -> pure ()
      _ -> failing ("abstract " ++ f ++ " must take " ++ prettyType (modelState m) ++ " to " ++ prettyType modelType)
  invariants <- forM (modelInvariants m) $ \p -> case definitionType p of
    Just (Arrow a b) | shape b == Named "Bool" && shape a == shape modelType -> pure (OnModel p)
    Just (Arrow a b) | shape b == Named "Bool" && isState a -> pure (OnState p)
    _ -> failing ("invariant " ++ p ++ " must be a checked definition taking " ++ prettyType modelType ++
      " or " ++ prettyType (modelState m) ++ " to Bool")
  (start, startDefinition) <- case modelStart m of
    Nothing -> pure (Nothing, Nothing)
    Just (f, initial) -> do
      ty <- maybe (failing ("start " ++ f ++ " has no signature")) pure (signatureOf f)
      let (args, result) = arguments ty
      unless (isState result && all (null . flowOfList) args)
        (failing ("start " ++ f ++ " must return " ++ family ++ " without taking a state"))
      fixed <- case stateHead result of
        Just (_, indices) -> pure (mapM constant indices)
        Nothing -> pure Nothing
      let generated = modelName m ++ "Start"
          parameters = [("input" ++ show i, a) | (i, a) <- zip [0 :: Int ..] args]
          body = case stripLocation initial of
            Var g | Just _ <- definitionType g, not (all isUnitType args) ->
              foldl Apply (Var g) [Var p | (p, _) <- parameters]
            e -> e
      unless (all isUnitType args) $ case stripLocation initial of
        Var g -> reference ("start " ++ f ++ "'s model state") g (foldr Arrow modelType args)
        _ -> failing ("start " ++ f ++ " takes arguments, so its model state must be a definition taking the same arguments")
      pure (Just (MachineStart f generated fixed (bridge "Begin")),
        Just (FunctionDefinition generated (if null parameters then [("input", Named "Unit")] else parameters) modelType [] body (modelSpan m)))
  let abstractRun = case modelAbstract m of
        Just f | null (definitionOf f) -> Just (bridge "Abstract")
        other -> other
  pure (Machine (modelName m) (modelShared m) family (length indexVariables) start commands (modelAbstract m) abstractRun invariants False [], startDefinition)
  where
    -- A generated bridge's name: the model's, then its role.
    bridge role = modelName m ++ role
    flowOfList t = maybe [] (const [()]) (flowOf t)

-- What each index must be before a command, and how the command changes it:
-- n + a before (at least a) or a constant k (exactly k); n + b after (a
-- shift of b - a) or a constant k (set to k).
typestate :: (String -> Failure) -> [String] -> Type -> Type -> Either Failure ([Need], [Shift])
typestate failure variables before after = do
  let failing :: String -> Either Failure a
      failing = Left . failure
  (_, ins) <- maybe (failing "through an unknown type") pure (stateHead before)
  (_, outs) <- maybe (failing "through an unknown type") pure (stateHead after)
  unless (length ins == length variables && length outs == length variables) (failing "with the wrong number of indices")
  results <- forM (zip ins outs) $ \(i, o) -> do
    (need, base) <- case pattern i of
      Just (Left v) -> pure (AtLeast 0, Just (v, 0))
      Just (Right (Left (v, k))) -> pure (AtLeast k, Just (v, k))
      Just (Right (Right k)) -> pure (Exactly k, Nothing)
      Nothing -> failing "in a form other than n, n + k or a constant"
    shift <- case (pattern o, base) of
      (Just (Right (Right k)), _) -> pure (To k)
      (Just (Left v), Just (v', a)) | v == v' -> pure (By (negate a))
      (Just (Right (Left (v, b))), Just (v', a)) | v == v' -> pure (By (b - a))
      _ -> failing "in a form other than its own index plus or minus a constant, or a constant"
    pure (need, shift)
  pure (map fst results, map snd results)

-- An index: a variable, a variable plus a constant, or a constant.
pattern :: Expr -> Maybe (Either String (Either (String, Integer) Integer))
pattern e = case stripLocation e of
  Var v -> Just (Left v)
  Binary "+" a b -> case (stripLocation a, stripLocation b) of
    (Var v, Number k) -> Just (Right (Left (v, k)))
    (Number k, Var v) -> Just (Right (Left (v, k)))
    _ -> Nothing
  Number k -> Just (Right (Right k))
  _ -> Nothing

constant :: Expr -> Maybe Integer
constant e = case pattern e of
  Just (Right (Right k)) -> Just k
  _ -> Nothing

stripLocation :: Expr -> Expr
stripLocation (Located _ e) = stripLocation e
stripLocation e = e

-- A state type's name and its index expressions.
stateHead :: Type -> Maybe (String, [Expr])
stateHead ty = case unrefinedType ty of
  RefinementApp n args | Just family <- stripSuffix (indexedRefinementName "") n ->
    Just (family, [e | ValueArgument e <- args])
  Named n -> Just (n, [])
  Applied n _ -> Just (n, [])
  Application n _ | n /= flowTypeName -> Just (n, [])
  _ -> Nothing
  where
    stripSuffix suffix n
      | length n > length suffix && drop (length n - length suffix) n == suffix = Just (take (length n - length suffix) n)
      | otherwise = Nothing

flowOf :: Type -> Maybe (Type, Type)
flowOf ty = case ty of
  Application n [a, b] | n == flowTypeName -> Just (a, b)
  _ -> Nothing

arguments :: Type -> ([Type], Type)
arguments (Arrow a b) = let (as, r) = arguments b in (a : as, r)
arguments t = ([], t)

unrefinedType :: Type -> Type
unrefinedType (Refined _ t _) = unrefinedType t
unrefinedType (Qualified _ t) = unrefinedType t
unrefinedType (CheckedType _ t) = unrefinedType t
unrefinedType t = t

isUnitType :: Type -> Bool
isUnitType t = unrefinedType t == Named "Unit"

-- A type's shape for comparison: refinements, qualifiers and indices erased.
shape :: Type -> Type
shape ty = case unrefinedType ty of
  -- Results compare by value, so integer types are interchangeable.
  Named n | isInteger n -> Named "Integer"
  Arrow a b -> Arrow (shape a) (shape b)
  Applied n t -> Applied n (shape t)
  Application n ts -> Application n (map shape ts)
  t@(RefinementApp _ _) | Just (family, _) <- stateHead t -> Named family
  RefinementApp n args -> RefinementApp n [TypeArgument (shape a) | TypeArgument a <- args]
  t -> t

typeVariablesOf :: Type -> [String]
typeVariablesOf ty = case ty of
  Variable v -> [v]
  Arrow a b -> typeVariablesOf a ++ typeVariablesOf b
  Applied _ t -> typeVariablesOf t
  Application _ ts -> concatMap typeVariablesOf ts
  Refined _ t _ -> typeVariablesOf t
  RefinementApp _ args -> concat [typeVariablesOf t | TypeArgument t <- args]
  Qualified _ t -> typeVariablesOf t
  CheckedType _ t -> typeVariablesOf t
  _ -> []

-- Whether a type's index expressions mention any of the variables.
mentions :: [String] -> Type -> Bool
mentions vs ty = case unrefinedType ty of
  RefinementApp _ args -> or ([any (`elem` vs) (exprVariables e) | ValueArgument e <- args] ++ [mentions vs t | TypeArgument t <- args])
  Arrow a b -> mentions vs a || mentions vs b
  Applied _ t -> mentions vs t
  Application _ ts -> any (mentions vs) ts
  _ -> False
  where
    exprVariables e = case stripLocation e of
      Var v -> [v]
      Binary _ a b -> exprVariables a ++ exprVariables b
      Apply a b -> exprVariables a ++ exprVariables b
      _ -> []

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

generatedNames :: Machine String -> [String]
generatedNames machine = map commandRun (machineCommands machine) ++ maybe [] (pure . startRun) (machineStart machine) ++
  [r | Just r <- [machineAbstractRun machine], Just r /= machineAbstract machine]

-- A `behaves like` model's reference definitions, generated from the
-- collection's operations, and the key argument of each command (for sets
-- and maps). Other models pass through unchanged.
behaviour :: Unit -> ModelDeclaration -> Either Failure (ModelDeclaration, [FunctionDefinition], [(String, Maybe Int)])
behaviour u m
  | not (modelBehaves m) = do
      forM_ (modelCommands m) $ \c -> when (modelAs c)
        (failing ("command " ++ modelCommand c ++ " uses `as`, which needs `behaves like` a collection"))
      pure (m, [], [])
  | otherwise = do
      (kind, elements) <- maybe (failing ("behaves like needs Set, KeyVal, Queue, Stack or Deque, not " ++ prettyType (modelBy m))) pure
        (collection (modelBy m))
      generated <- forM (modelCommands m) $ \c -> do
        unless (modelAs c) (failing ("command " ++ modelCommand c ++ " must name the " ++ kind ++ " operation it implements with `as`"))
        (inputs, result, body, key) <- maybe
          (failing ("command " ++ modelCommand c ++ ": " ++ kind ++ " has no operation " ++ modelReference c ++
            "; it has " ++ unwords (operations kind)))
          pure (operation kind elements (modelReference c))
        let name = modelName m ++ capitalize (modelCommand c) ++ "Reference"
            parameters = [("argument" ++ show i, t) | (i, t) <- zip [0 :: Int ..] inputs] ++ [("state", modelBy m)]
            resultType = maybe (modelBy m) (\r -> Application "Pair" [r, modelBy m]) result
        pure (c { modelReference = name, modelAs = False },
          FunctionDefinition name parameters resultType [] body (modelSpan m), (modelCommand c, key))
      let start = case modelStart m of
            Just (f, Var "") -> Just (f, Apply (Var ("prelude." ++ constructorOf kind)) (ListLit []))
            other -> other
      pure (m { modelCommands = [c | (c, _, _) <- generated], modelStart = start },
        [d | (_, d, _) <- generated], [(n, k) | (_, _, (n, k)) <- generated])
  where
    failing message = Left (Just (modelSpan m), "model " ++ modelName m ++ ": " ++ message)
    _ = u

-- A collection type's kind and element types.
collection :: Type -> Maybe (String, [Type])
collection ty = case unrefinedType ty of
  Applied n t | n `elem` ["Set", "Queue", "Stack", "Deque"] -> Just (n, [t])
  Application n [k, v] | n == "KeyVal" -> Just (n, [k, v])
  Application n [t] | n `elem` ["Set", "Queue", "Stack", "Deque"] -> Just (n, [t])
  _ -> Nothing

constructorOf :: String -> String
constructorOf kind = case kind of
  "Set" -> "setOf"
  "KeyVal" -> "keyValOf"
  "Queue" -> "queueOf"
  "Stack" -> "stackOf"
  _ -> "dequeOf"

operations :: String -> [String]
operations kind = case kind of
  "Queue" -> ["offer", "poll", "peek", "size", "isEmpty"]
  "Stack" -> ["push", "pop", "peek", "size", "isEmpty"]
  "Deque" -> ["pushFront", "pushBack", "popFront", "popBack", "peekFront", "peekBack", "size", "isEmpty"]
  "Set" -> ["add", "remove", "contains", "size", "isEmpty"]
  _ -> ["put", "get", "remove", "putIfAbsent", "containsKey", "size", "isEmpty"]

-- An operation's other arguments, its result (Nothing for Unit), its body
-- over `state` and `argument<i>`, and which argument is its key.
operation :: String -> [Type] -> String -> Maybe ([Type], Maybe Type, Expr, Maybe Int)
operation kind elements op = case (kind, elements, op) of
  (_, _, "size") -> Just ([], Just (Named "Integer"), pair (call "size" [s]) s, Nothing)
  (_, _, "isEmpty") -> Just ([], Just (Named "Bool"), pair (call "isEmpty" [s]) s, Nothing)
  ("Queue", [t], "offer") -> Just ([t], Nothing, call "enqueue" [a 0, s], Nothing)
  ("Queue", [t], "poll") -> Just ([], Just (maybeOf t), pair (call "front" [s]) (call "dequeue" [s]), Nothing)
  ("Queue", [t], "peek") -> Just ([], Just (maybeOf t), pair (call "front" [s]) s, Nothing)
  ("Stack", [t], "push") -> Just ([t], Nothing, call "push" [a 0, s], Nothing)
  ("Stack", [t], "pop") -> Just ([], Just (maybeOf t), pair (call "peek" [s]) (call "pop" [s]), Nothing)
  ("Stack", [t], "peek") -> Just ([], Just (maybeOf t), pair (call "peek" [s]) s, Nothing)
  ("Deque", [t], "pushFront") -> Just ([t], Nothing, call "pushFront" [a 0, s], Nothing)
  ("Deque", [t], "pushBack") -> Just ([t], Nothing, call "pushBack" [a 0, s], Nothing)
  ("Deque", [t], "popFront") -> Just ([], Just (maybeOf t), pair (call "peekFront" [s]) (call "popFront" [s]), Nothing)
  ("Deque", [t], "popBack") -> Just ([], Just (maybeOf t), pair (call "peekBack" [s]) (call "popBack" [s]), Nothing)
  ("Deque", [t], "peekFront") -> Just ([], Just (maybeOf t), pair (call "peekFront" [s]) s, Nothing)
  ("Deque", [t], "peekBack") -> Just ([], Just (maybeOf t), pair (call "peekBack" [s]) s, Nothing)
  ("Set", [t], "add") -> Just ([t], Just (Named "Bool"),
    pair (call "select" [call "member" [a 0, s], BoolLit False, BoolLit True]) (call "insert" [a 0, s]), Just 0)
  ("Set", [t], "remove") -> Just ([t], Just (Named "Bool"), pair (call "member" [a 0, s]) (call "remove" [a 0, s]), Just 0)
  ("Set", [t], "contains") -> Just ([t], Just (Named "Bool"), pair (call "member" [a 0, s]) s, Just 0)
  ("KeyVal", [k, v], "put") -> Just ([k, v], Just (maybeOf v), pair (call "lookup" [a 0, s]) (call "put" [a 0, a 1, s]), Just 0)
  ("KeyVal", [k, _], "get") -> Just ([k], Just (maybeOf (elements !! 1)), pair (call "lookup" [a 0, s]) s, Just 0)
  ("KeyVal", [k, v], "remove") -> Just ([k], Just (maybeOf v), pair (call "lookup" [a 0, s]) (call "delete" [a 0, s]), Just 0)
  ("KeyVal", [k, v], "putIfAbsent") -> Just ([k, v], Just (maybeOf v),
    pair (call "lookup" [a 0, s]) (absent (call "put" [a 0, a 1, s]) s), Just 0)
  ("KeyVal", [k, _], "containsKey") -> Just ([k], Just (Named "Bool"), pair (absent (BoolLit False) (BoolLit True)) s, Just 0)
  _ -> Nothing
  where
    s = Var "state"
    a i = Var ("argument" ++ show (i :: Int))
    call f args = foldl Apply (Var ("prelude." ++ f)) args
    pair x y = ConstructLit "Pair" [x, y]
    maybeOf t = Applied "Maybe" t
    -- The first value when the key is absent, the second when present.
    absent none some = MatchExpr (call "lookup" [a 0, s])
      [MatchBranch "Nothing" [] none, MatchBranch "Just" ["present"] some]
