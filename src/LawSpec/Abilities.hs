-- Abilities, handlers and ability rows on the surface unit (see
-- docs/explanation/abilities.md). An ability declares operations; a
-- signature or definition says which abilities it uses; a handler gives an
-- ability's operations meaning. This pass runs once per unit, after parsing:
--
--   * each ability's operations join the unit's functions, so laws and
--     definitions type-check calls to them like any other call (elaboration
--     turns those calls into Core's Perform);
--   * each spec handler clause becomes a checked definition, so the totality
--     audit proves it like any other (a clause of a handler with state takes
--     the state first and returns Pair result state);
--   * every function gets its ability row: declared on an adapter, inferred
--     for a definition as the least row that covers everything it calls
--     (rows are closed sets: definitions are first order, so the row
--     variable of each definition is closed when it is checked, as in Koka
--     after generalization);
--   * every law that uses abilities is given the handlers it runs under: the
--     ones it names with `using`, and otherwise each lawful handler in turn
--     (the native production handler, then each spec handler), one law per
--     choice. Each ability law becomes one law per handler, so evidence holds
--     one obligation per (ability law, handler).
module LawSpec.Abilities
  ( elaborateAbilities, clauseDefinitionName, describeChoices
  , abilityArguments, instantiatedOperations, usesAbilities
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toUpper, isLower)
import Data.List (intercalate, isInfixOf, nub, sortOn, (\\))
import qualified Data.Map.Strict as M
import LawSpec.Model

type Failure = (Maybe Location, String)

-- Whether a unit's source mentions anything this pass handles.
usesAbilities :: Unit -> Bool
usesAbilities u = not (null (abilities u) && null (handlerDeclarations u) && null (declaredUses u) && null (lawHandlers u))
  || any (`isInfixOf` text) ["Var \"prelude.raise\"", "Var \"prelude.calls\"", "Var \"prelude.attempt\""]
  where text = show (functionDefinitions u, laws u)

-- A handler clause's checked definition: fakeGateway's authorize clause is
-- fakeGatewayAuthorize.
clauseDefinitionName :: String -> String -> String
clauseDefinitionName handler operation = handler ++ capitalize operation

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

-- An ability type's arguments: Store Int32 has [Int32].
abilityArguments :: Type -> [Type]
abilityArguments t = case t of
  Applied _ a -> [a]
  Application _ as -> as
  _ -> []

-- An ability's operations at an instance's type arguments.
instantiatedOperations :: AbilityDeclaration -> Type -> [(String, Type)]
instantiatedOperations ability instance' =
  let table = zip (abilityParameters ability) (abilityArguments instance')
      go = mapType (\t -> case t of Variable v -> maybe t id (lookup v table); _ -> t) id
  in [(op, go ty) | (op, ty) <- abilityOperations ability]

-- How a law's name describes the handlers it runs under.
describeChoices :: [(Type, HandlerChoice)] -> String
describeChoices assignment = "[" ++ intercalate ", " (map describe assignment) ++ "]"
  where
    single = length assignment == 1
    describe (ability, choice) = case choice of
      ChooseProduction -> if single then "native" else "native " ++ prettyType ability
      ChooseSpec h -> h
      ChooseRecording c -> "recording " ++ describe (ability, c)

elaborateAbilities :: Unit -> Either Failure Unit
elaborateAbilities u
  | not (usesAbilities u) = pure u
  | otherwise = do
  let declared = abilities u
      at s = Just (spanStart s)
      located = Just . spanStart
      byName = M.fromList [(abilityName a, a) | a <- declared]
      functionNames = map fst (functions u)
  -- Declarations.
  forM_ declared $ \a -> do
    when (length (filter ((== abilityName a) . abilityName) declared) > 1)
      (Left (at (abilitySpan a), "the ability " ++ abilityName a ++ " is declared twice"))
    when (abilityName a == failAbilityName)
      (Left (at (abilitySpan a), "Fail is built in: write `fails with E` to use it"))
    when (abilityName a `elem` map dataTypeName (dataTypes u))
      (Left (at (abilitySpan a), "the ability " ++ abilityName a ++ " has the name of a type"))
    forM_ (abilityOperations a) $ \(op, ty) -> do
      unless (maybe False isLower (headMaybe op))
        (Left (at (abilitySpan a), "the operation " ++ op ++ " of " ++ abilityName a ++ " must start with a lowercase letter"))
      when (refined ty)
        (Left (at (abilitySpan a), "the operation " ++ op ++ " has a refined type; for now, put the constraint in a wrapper type"))
      forM_ (typeVariablesOf ty) $ \v -> unless (v `elem` abilityParameters a)
        (Left (at (abilitySpan a), "the operation " ++ op ++ " mentions " ++ v ++ ", which is not a type parameter of " ++ abilityName a))
  let allOperations = [(op, a) | a <- declared, (op, _) <- abilityOperations a]
  forM_ allOperations $ \(op, a) -> do
    when (length (filter ((== op) . fst) allOperations) > 1)
      (Left (at (abilitySpan a), "two abilities have an operation called " ++ op ++ "; operation names must be unique in a unit"))
    when (op `elem` functionNames)
      (Left (at (abilitySpan a), "the operation " ++ op ++ " of " ++ abilityName a ++ " has the name of a function"))
  -- Ability types mentioned by uses lists and handlers must exist, with
  -- the right number of type arguments.
  let checkAbilityType where' t = case abilityTypeName t of
        n | n == failAbilityName -> unless (length (abilityArguments t) == 1)
              (Left (where', "Fail takes one type: the type of the failure, as in `fails with Declined`"))
        n -> case M.lookup n byName of
          Nothing -> Left (where', "there is no ability called " ++ n ++ " in this unit")
          Just a -> unless (length (abilityArguments t) == length (abilityParameters a))
            (Left (where', n ++ " takes " ++ show (length (abilityParameters a)) ++ " type argument(s)"))
      spanOf n = lookup n (declarationSpans u)
  forM_ (declaredUses u) $ \(n, used) -> mapM_ (checkAbilityType (located =<< spanOf n)) used
  forM_ (handlerDeclarations u) $ \h -> checkAbilityType (at (handlerSpan h)) (handlerAbility h)
  -- Instances: a parameterized ability is used at one type per unit, for
  -- now; its operations are typed at that instance.
  let mentioned = concatMap snd (declaredUses u) ++ map handlerAbility (handlerDeclarations u)
  instances <- fmap concat $ forM declared $ \a ->
    if null (abilityParameters a) then pure [(abilityName a, Named (abilityName a))]
    else case nub [t | t <- mentioned, abilityTypeName t == abilityName a] of
      [] -> pure []
      [t] -> pure [(abilityName a, t)]
      ts -> Left (at (abilitySpan a), "this unit uses " ++ abilityName a ++ " at more than one type (" ++
        intercalate ", " (map prettyType ts) ++ "); for now a unit may use a parameterized ability at one type")
  let instanceOf n = lookup n instances
      operationTypes = [(op, ty) | a <- declared, Just inst <- [instanceOf (abilityName a)], (op, ty) <- instantiatedOperations a inst]
      operationAbility = M.fromList [(op, inst) | a <- declared, Just inst <- [instanceOf (abilityName a)], (op, _) <- abilityOperations a]
  -- Spec handlers: one checked definition per clause.
  clauseDefinitions <- fmap concat $ forM (handlerDeclarations u) $ \h -> do
    let where' = at (handlerSpan h)
        abilityTy = handlerAbility h
    when (abilityTypeName abilityTy == failAbilityName)
      (Left (where', "Fail's handler is built in; handlers for Fail are not supported yet"))
    a <- maybe (Left (where', "there is no ability called " ++ abilityTypeName abilityTy)) Right (M.lookup (abilityTypeName abilityTy) byName)
    when (length (filter ((== handlerName h) . handlerName) (handlerDeclarations u)) > 1)
      (Left (where', "the handler " ++ handlerName h ++ " is declared twice"))
    unless (maybe False isLower (headMaybe (handlerName h)))
      (Left (where', "handler names start with a lowercase letter"))
    let operations = instantiatedOperations a abilityTy
        clauseNames = map clauseOperation (handlerClauses h)
    forM_ (nub clauseNames) $ \c -> do
      when (length (filter (== c) clauseNames) > 1)
        (Left (where', "the handler " ++ handlerName h ++ " has two clauses for " ++ c))
      unless (c `elem` map fst operations)
        (Left (where', abilityName a ++ " has no operation called " ++ c ++ ", so " ++ handlerName h ++ " cannot handle it"))
    forM operations $ \(op, ty) -> do
      clause <- maybe (Left (where', "the handler " ++ handlerName h ++ " for " ++ prettyType abilityTy ++
        " has no clause for " ++ op)) Right (lookup op [(clauseOperation c, c) | c <- handlerClauses h])
      let (parameters, result) = functionType ty
          name = clauseDefinitionName (handlerName h) op
          clauseAt = at (clauseSpan clause)
      unless (length (clauseParameters clause) == length parameters)
        (Left (clauseAt, "the clause for " ++ op ++ " in " ++ handlerName h ++ " takes " ++
          show (length parameters) ++ " value(s), as " ++ op ++ " :: " ++ prettyType ty ++ " does"))
      when (name `elem` functionNames)
        (Left (clauseAt, "the clause for " ++ op ++ " in " ++ handlerName h ++ " would be the definition " ++ name ++ ", which already exists"))
      let arguments = zip (clauseParameters clause) parameters
      case handlerState h of
        Nothing -> pure (FunctionDefinition name
          (if null arguments then [("lawspecUnit", Named "Unit")] else arguments)
          result [] (clauseBody clause) (clauseSpan clause))
        Just (state, stateType, _) -> do
          when (state `elem` clauseParameters clause)
            (Left (clauseAt, "a clause's value cannot have the name of the handler's state, " ++ state))
          body <- stateful clauseAt state (clauseBody clause)
          pure (FunctionDefinition name ((state, stateType) : arguments)
            (Application "Pair" [result, stateType]) [] body (clauseSpan clause))
  let definitions = functionDefinitions u ++ clauseDefinitions
      definitionTable = M.fromList [(functionName d, d) | d <- definitions]
      clauseNames = map functionName clauseDefinitions
      functions' = functions u ++ operationTypes ++
        [(functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))) | d <- clauseDefinitions]
      known = M.fromList [(n, ()) | (n, _) <- functions']
      declaredRow n = lookup n (declaredUses u)
      references d = nub [x | x <- exprVars (functionBody d), x `notElem` map fst (functionArguments d), M.member x known]
      raises d = "prelude.raise" `elem` exprVars (functionBody d)
      fixedRow n
        | Just inst <- M.lookup n operationAbility = Just [inst]
        | M.member n definitionTable = Nothing
        | otherwise = Just (maybe [] id (declaredRow n))
  -- Rows: the least fixed point over the call graph.
  forM_ definitions $ \d -> when (raises d && null [t | Just ts <- [declaredRow (functionName d)], t <- ts, abilityTypeName t == failAbilityName])
    (Left (at (functionSpan d), functionName d ++ " raises a failure, so its signature must say what it fails with: add `fails with` and the failure's type"))
  forM_ definitions $ \d -> when ("prelude.attempt" `elem` exprVars (functionBody d))
    (Left (at (functionSpan d), functionName d ++ ": prelude.attempt is for laws, for now"))
  let rowOf table n = maybe (M.findWithDefault [] n table) id (fixedRow n)
      step table = M.fromList
        [ (functionName d, canonical (concatMap (rowOf table) (references d) ++
            (if raises d then [t | Just ts <- [declaredRow (functionName d)], t <- ts, abilityTypeName t == failAbilityName] else [])))
        | d <- definitions ]
      solve table = let next = step table in if next == table then table else solve next
      inferred = solve (M.fromList [(functionName d, []) | d <- definitions])
      finalRow n = case declaredRow n of
        Just row -> row
        Nothing -> rowOf inferred n
  forM_ definitions $ \d -> do
    let row = M.findWithDefault [] (functionName d) inferred
        where' = at (functionSpan d)
    when (functionName d `elem` clauseNames && not (null row))
      (Left (where', "the handler clause " ++ functionName d ++ " uses " ++ intercalate ", " (map prettyType row) ++
        "; handler clauses cannot use abilities yet"))
    case declaredRow (functionName d) of
      Nothing -> pure ()
      Just listed -> forM_ row $ \ability -> unless (ability `elem` listed) $ do
        let through = [r | r <- references d, ability `elem` rowOf inferred r]
        Left (where', functionName d ++ " uses " ++ prettyType ability ++
          (case through of r : _ -> " (through " ++ r ++ ")"; [] -> "") ++
          ", but its uses list does not say so; add " ++ prettyType ability ++ " to it")
  let rows = [(n, finalRow n) | n <- map fst (functions u) ++ clauseNames, n `M.notMember` operationAbility, not (null (finalRow n))]
      rowTable = M.fromList rows
      nameRow n = maybe (M.findWithDefault [] n rowTable) pure (M.lookup n operationAbility)
      defaults inst
        | abilityTypeName inst == failAbilityName = [ChooseProduction]
        | otherwise = ChooseProduction : [ChooseSpec (handlerName h) | h <- handlerDeclarations u, handlerAbility h == inst]
      lawTable = M.fromList [(lawName l, l) | l <- laws u]
      -- The abilities a law needs: everything its clauses and examples call,
      -- through the laws it invokes.
      lawRow seen l =
        let own = canonical (concatMap nameRow (lawReferences l) ++ concatMap (maybe [] pure . (`M.lookup` operationAbility)) (countedOperations l))
            invoked = [i | n <- invokedNames (definition l), n `notElem` seen, Just i <- [M.lookup n lawTable]]
        in canonical (own ++ concatMap (lawRow (lawName l : seen)) invoked)
      lawReferences l = [x | x <- lawNames l, M.member x known]
      handlerAbilities = M.fromList [(handlerName h, handlerAbility h) | h <- handlerDeclarations u]
      -- What `using` asks for, by ability name.
      request where' use = case use of
        UseHandler h -> case M.lookup h handlerAbilities of
          Just inst -> pure (abilityTypeName inst, Left (ChooseSpec h))
          Nothing -> Left (where', "there is no handler called " ++ h)
        UseAbility n
          | M.member n byName || n == failAbilityName -> pure (n, Right False)
          | otherwise -> Left (where', "there is no ability called " ++ n)
        UseRecording (UseRecording _) -> Left (where', "recording a recording is not supported")
        UseRecording inner -> do
          (n, r) <- request where' inner
          when (n == failAbilityName) (Left (where', "Fail cannot be recorded"))
          pure (n, either (Left . ChooseRecording) (const (Right True)) r)
      choicesFor l = do
        let where' = Just (location l)
            row = lawRow [] l
        requested <- mapM (request where') (maybe [] id (lookup (lawName l) (lawHandlers u)))
        forM_ requested $ \(n, _) -> do
          when (length (filter ((== n) . fst) requested) > 1)
            (Left (where', "the law " ++ lawName l ++ " names two handlers for " ++ n))
          unless (n `elem` map abilityTypeName row)
            (Left (where', "the law " ++ lawName l ++ " names a handler for " ++ n ++ ", but nothing it calls uses " ++ n))
        let candidates inst = case lookup (abilityTypeName inst) requested of
              Just (Left c) -> [c]
              Just (Right recorded) -> (if recorded then map ChooseRecording else id) (defaults inst)
              Nothing -> defaults inst
        forM_ (countedOperations l) $ \op -> case M.lookup op operationAbility of
          Nothing -> Left (where', "calls of " ++ op ++ ": " ++ op ++ " is not an ability operation")
          Just inst -> unless (all recording (candidates inst))
            (Left (where', "the law " ++ lawName l ++ " counts calls of " ++ op ++ ", so it needs a recording handler: add `using recording " ++
              abilityTypeName inst ++ "` (or `recording` and a handler's name)"))
        pure [(inst, candidates inst) | inst <- row]
      variants l choices
        | null choices = [(l, [])]
        | otherwise =
            let base = [(inst, head cs) | (inst, cs) <- choices]
                others = [[(i, if i == inst then c else b) | (i, b) <- base] | (inst, cs) <- choices, c <- drop 1 cs]
                assignments = base : others
            in if length assignments == 1 then [(l, base)]
               else [(l { lawName = lawName l ++ " " ++ describeChoices a }, a) | a <- assignments]
  -- prelude.attempt e catches the failure e's row says it may raise: its
  -- type is given here, since a law's sides are typed one at a time.
  let failuresOf e = nub [t | n <- exprVars e, M.member n known, t <- nameRow n, abilityTypeName t == failAbilityName]
      attemptIn where' e = case e of
        Located r inner -> Located r <$> attemptIn where' inner
        Apply (Var "prelude.attempt") body -> attempted body
        Apply (Located _ (Var "prelude.attempt")) body -> attempted body
        Apply f x -> Apply <$> attemptIn where' f <*> attemptIn where' x
        Binary op a b -> Binary op <$> attemptIn where' a <*> attemptIn where' b
        Unary op a -> Unary op <$> attemptIn where' a
        Annotate a t -> (`Annotate` t) <$> attemptIn where' a
        ConstructLit n fields -> ConstructLit n <$> mapM (attemptIn where') fields
        ListLit xs -> ListLit <$> mapM (attemptIn where') xs
        MatchExpr v branches -> MatchExpr <$> attemptIn where' v <*>
          mapM (\(MatchBranch tag names body) -> MatchBranch tag names <$> attemptIn where' body) branches
        _ -> pure e
        where
          attempted body = do
            body' <- attemptIn where' body
            case failuresOf body' of
              [Applied _ failure] -> pure (Annotate (Apply (Var "prelude.attempt") body')
                (Application "Either" [failure, Variable ("attempt:" ++ show (spanKey where'))]))
              [] -> Left (where', "prelude.attempt: nothing in " ++ prettyExpr body' ++ " can fail")
              many -> Left (where', "prelude.attempt: " ++ prettyExpr body' ++ " can fail in more than one way (" ++
                intercalate ", " (map prettyType many) ++ ")")
      spanKey where' = maybe 0 (\(Location _ line column) -> line * 1000 + column) where'
      attemptLaw l = do
        let where' = Just (location l)
            go d = case d of
              Forall bound body -> Forall bound <$> go body
              Equal a b -> Equal <$> attemptIn where' a <*> attemptIn where' b
              Holds a -> Holds <$> attemptIn where' a
              Implies a body -> Implies <$> attemptIn where' a <*> go body
              And a b -> And <$> go a <*> go b
              Invoke n args -> Invoke n <$> mapM (attemptIn where') args
        d' <- go (definition l)
        examples' <- forM (examples l) $ \ex -> do
          checks <- forM (expectations ex) $ \c -> (\a -> c { actual = a }) <$> attemptIn where' (actual c)
          pure ex { expectations = checks }
        pure l { definition = d', examples = examples' }
  attemptedLaws <- mapM attemptLaw (laws u)
  -- Ordinary laws: concrete ones get their handlers; generic ones are
  -- templates, instantiated where they are invoked.
  expandedLaws <- fmap concat $ forM attemptedLaws $ \l ->
    if not (null (parameters l)) then pure [(l, [])] else variants l <$> choicesFor l
  -- Ability laws: one per handler of the ability.
  abilityLawCopies <- fmap concat $ forM declared $ \a -> case instanceOf (abilityName a) of
    Nothing -> pure []
    Just inst -> fmap concat $ forM (abilityLaws a) $ \l -> do
      unless (null (parameters l))
        (Left (Just (location l), "an ability's laws must be closed: quantify their values with `for all`"))
      let row = lawRow [] l
          others = [(i, head (defaults i)) | i <- row, i /= inst]
      pure [ (l { lawName = prettyType inst ++ ": " ++ lawName l ++ " " ++ describeChoices [(inst, c)] }, (inst, c) : others)
           | c <- defaults inst ]
  let allLaws = expandedLaws ++ abilityLawCopies
      names = map (lawName . fst) allLaws
  forM_ names $ \n -> when (length (filter (== n) names) > 1)
    (Left (Nothing, "two laws are called " ++ n ++ " once their handlers are named"))
  pure u
    { functions = functions'
    , functionDefinitions = definitions
    , declarationSpans = declarationSpans u ++
        [(op, abilitySpan a) | a <- declared, (op, _) <- abilityOperations a] ++
        [(functionName d, functionSpan d) | d <- clauseDefinitions]
    , laws = map fst allLaws
    , abilityRows = rows
    , lawAssignments = [(lawName l, a) | (l, a) <- allLaws, not (null a)]
    }
  where
    headMaybe xs = case xs of x : _ -> Just x; [] -> Nothing
    recording c = case c of ChooseRecording _ -> True; _ -> False
    canonical = sortOn prettyType . nub

-- A clause of a handler with state s: `~s := e;` statements, then the
-- result. Each statement sees the state the ones before it left. The clause
-- gives Pair result state.
stateful :: Maybe Location -> String -> Expr -> Either Failure Expr
stateful at state = go (Var state)
  where
    go current e = case unlocated e of
      Binary ";" first rest -> case unlocated first of
        Binary ":=" target value | unlocated target == Var ('~' : state) -> go (replace current value) rest
        _ -> Left (at, "in a handler clause, only `~" ++ state ++ " := value;` may come before the result")
      Binary ":=" _ _ -> Left (at, "a handler clause ends with its result, after `~" ++ state ++ " := value;`")
      _ -> do
        let result = replace current e
        when ("Var \"~" `isInfixOf` show result) (Left (at, "~" ++ state ++ " may appear only on the left of :="))
        pure (ConstructLit "Pair" [result, current])
    replace current = replaceExprVars [(state, current)]

refined :: Type -> Bool
refined ty = case ty of
  Refined _ _ _ -> True
  RefinementApp _ _ -> True
  CheckedType _ _ -> True
  Arrow a b -> refined a || refined b
  Applied _ a -> refined a
  Application _ as -> any refined as
  Qualified _ t -> refined t
  _ -> False

typeVariablesOf :: Type -> [String]
typeVariablesOf ty = nub $ case ty of
  Variable n -> [n]
  Arrow a b -> typeVariablesOf a ++ typeVariablesOf b
  Applied _ a -> typeVariablesOf a
  Application _ as -> concatMap typeVariablesOf as
  Refined _ t _ -> typeVariablesOf t
  Qualified _ t -> typeVariablesOf t
  CheckedType _ t -> typeVariablesOf t
  _ -> []

-- The names a law's clauses and examples mention, less those it quantifies.
lawNames :: Law -> [String]
lawNames l = nub (definitionNames (definition l) ++ concat [concatMap (exprVars . actual) (expectations e) | e <- examples l]) \\ map fst (parameters l)
  where
    definitionNames d = case d of
      Forall bound body -> definitionNames body \\ map fst bound
      Equal a b -> exprVars a ++ exprVars b
      Holds a -> exprVars a
      Implies a body -> exprVars a ++ definitionNames body
      And a b -> definitionNames a ++ definitionNames b
      Invoke _ args -> concatMap exprVars args

invokedNames :: Definition -> [String]
invokedNames d = case d of
  Forall _ body -> invokedNames body
  Implies _ body -> invokedNames body
  And a b -> invokedNames a ++ invokedNames b
  Invoke n _ -> [n]
  _ -> []

-- The operations a law counts with `calls of`.
countedOperations :: Law -> [String]
countedOperations l = nub (go (definition l))
  where
    go d = case d of
      Forall _ body -> go body
      Equal a b -> counted a ++ counted b
      Holds a -> counted a
      Implies a body -> counted a ++ go body
      And a b -> go a ++ go b
      Invoke _ args -> concatMap counted args
    counted e = case unlocated e of
      Apply _ _ | (Var "prelude.calls", Var op : rest) <- spine e -> op : concatMap counted rest
      Apply f x -> counted f ++ counted x
      Binary _ a b -> counted a ++ counted b
      Unary _ a -> counted a
      Annotate a _ -> counted a
      ConstructLit _ fields -> concatMap counted fields
      ListLit xs -> concatMap counted xs
      MatchExpr v branches -> counted v ++ concat [counted b | MatchBranch _ _ b <- branches]
      Compose a b -> counted a ++ counted b
      _ -> []
    spine e = case unlocated e of
      Apply f x -> let (h, args) = spine f in (h, args ++ [unlocated x])
      other -> (other, [])
