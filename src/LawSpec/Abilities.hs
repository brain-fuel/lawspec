-- Abilities, handlers and ability rows on the surface unit (see
-- docs/explanation/abilities.md). An ability declares operations; a
-- signature or definition says which abilities it uses; a handler gives an
-- ability's operations meaning. This pass runs once per unit, after imports
-- (LawSpec.Imports copies the abilities and handlers of every unit a unit
-- imports, remembering the unit that declares each):
--
--   * each ability's operations join the unit's functions, so laws and
--     definitions type-check calls to them like any other call (elaboration
--     turns those calls into Core's Perform). A parameterized ability's
--     operations keep its type parameters, as variables that each use
--     instantiates (LawSpec.Inference.abilityVariable), so one unit may use
--     Store Int32 and Store Text;
--   * each spec handler clause becomes a checked definition, so the totality
--     audit proves it like any other (a clause of a handler with state takes
--     the state first and returns Pair result state);
--   * every function gets its ability row: declared on an adapter, inferred
--     for a definition as the least row that covers everything it calls,
--     less the abilities its `handle ... with h end` handles, plus what h's
--     clauses use (rows are closed sets: definitions are first order, so the
--     row variable of each definition is closed when it is checked, as in
--     Koka after generalization);
--   * every law that uses abilities is given the handlers it runs under: the
--     ones it names with `using`, and otherwise each lawful handler in turn
--     (the native production handler, then each spec handler), one law per
--     choice. Each ability law becomes one law per handler, so evidence holds
--     one obligation per (ability law, handler). An operation with a refined
--     type adds the law that its results keep the refinement.
module LawSpec.Abilities
  ( elaborateAbilities, clauseDefinitionName, describeChoices
  , abilityArguments, instantiatedOperations, usesAbilities, unqualifiedHandler
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toUpper, isLower)
import Data.List (intercalate, isInfixOf, nub, sortOn)
import qualified Data.Map.Strict as M
import LawSpec.Model
import LawSpec.Collections (collectionsUnit)

type Failure = (Maybe Location, String)

-- Whether a unit's source mentions anything this pass handles.
usesAbilities :: Unit -> Bool
usesAbilities u = not (null (abilities u) && null (handlerDeclarations u) && null (declaredUses u) && null (lawHandlers u))
  || any (`isInfixOf` text) ["Var \"prelude.raise\"", "Var \"prelude.calls\"", "Var \"prelude.attempt\"", "Var \"prelude.handle:"]
  where text = show (functionDefinitions u, laws u)

-- A handler clause's checked definition: fakeGateway's authorize clause is
-- fakeGatewayAuthorize.
clauseDefinitionName :: String -> String -> String
clauseDefinitionName handler operation = handler ++ capitalize operation

-- A handler's name without the import alias it may be written with.
unqualifiedHandler :: String -> String
unqualifiedHandler = reverse . takeWhile (/= '.') . reverse

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
      go = mapType (\t -> case t of Variable v -> maybe t id (lookup v table); _ -> t) (mapExprTypes go)
  in [(op, go ty) | (op, ty) <- abilityOperations ability]

-- How a law's name describes the handlers it runs under.
describeChoices :: [(Type, HandlerChoice)] -> String
describeChoices assignment = "[" ++ intercalate ", " (map describe named) ++ "]"
  where
    -- Fail has one handler, so it does not tell the variants apart.
    named = case filter ((/= failAbilityName) . abilityTypeName . fst) assignment of
      [] -> assignment
      xs -> xs
    single = length named == 1
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
      handlerTable = M.fromList [(handlerName h, h) | h <- handlerDeclarations u]
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
  -- Instances: each type an ability is used at, as uses lists and handlers
  -- name them. An ability without parameters has one.
  let mentioned = concatMap snd (declaredUses u) ++ map handlerAbility (handlerDeclarations u)
      instancesOf a
        | null (abilityParameters a) = [Named (abilityName a)]
        | otherwise = nub [t | t <- mentioned, abilityTypeName t == abilityName a]
      -- An operation's type, with its ability's parameters as variables each
      -- use instantiates.
      operationTypes = [(op, generic a ty) | a <- declared, (op, ty) <- abilityOperations a]
      generic a = mapType (\t -> case t of
        Variable v | v `elem` abilityParameters a -> Variable (abilityVariable (abilityName a) v)
        _ -> t) id
      operationAbility = M.fromList [(op, a) | a <- declared, (op, _) <- abilityOperations a]
      opInstances op = maybe [] instancesOf (M.lookup op operationAbility)
      handlerInstance name = handlerAbility <$> M.lookup (unqualifiedHandler name) handlerTable
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
      let (parameters', result) = functionType ty
          name = clauseDefinitionName (handlerName h) op
          clauseAt = at (clauseSpan clause)
      unless (length (clauseParameters clause) == length parameters')
        (Left (clauseAt, "the clause for " ++ op ++ " in " ++ handlerName h ++ " takes " ++
          show (length parameters') ++ " value(s), as " ++ op ++ " :: " ++ prettyType ty ++ " does"))
      when (name `elem` functionNames)
        (Left (clauseAt, "the clause for " ++ op ++ " in " ++ handlerName h ++ " would be the definition " ++ name ++ ", which already exists"))
      let arguments = zip (clauseParameters clause) parameters'
      case handlerState h of
        Nothing -> pure (FunctionDefinition name
          (if null arguments then [("lawspecUnit", Named "Unit")] else arguments)
          result [] (clauseBody clause) (clauseSpan clause))
        Just (state, stateType, _) -> do
          when (state `elem` clauseParameters clause)
            (Left (clauseAt, "a clause's value cannot have the name of the handler's state, " ++ state))
          body <- stateful clauseAt state (clauseBody clause)
          pure (FunctionDefinition name ((state, stateType) : arguments)
            (Application pairType [result, stateType]) [] body (clauseSpan clause))
  let definitions = functionDefinitions u ++ clauseDefinitions
      definitionTable = M.fromList [(functionName d, d) | d <- definitions]
      clauseNames = map functionName clauseDefinitions
      clauseOwner = M.fromList [(clauseDefinitionName (handlerName h) (clauseOperation c), h) | h <- handlerDeclarations u, c <- handlerClauses h]
      functions' = functions u ++ operationTypes ++
        [(functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))) | d <- clauseDefinitions]
      known = M.fromList [(n, ()) | (n, _) <- functions']
      declaredRow n = lookup n (declaredUses u)
      failures n = [t | Just ts <- [declaredRow n], t <- ts, abilityTypeName t == failAbilityName]
      fixedRow n
        | M.member n operationAbility = Just (opInstances n)
        | M.member n definitionTable = Nothing
        | otherwise = Just (maybe [] id (declaredRow n))
      rowOf table n = maybe (M.findWithDefault [] n table) id (fixedRow n)
      handlerClauseNames name = case M.lookup (unqualifiedHandler name) handlerTable of
        Just h -> [clauseDefinitionName (handlerName h) (clauseOperation c) | c <- handlerClauses h]
        Nothing -> []
      -- An expression's row: what it calls, less what its handle ... with h
      -- end regions handle, plus what h's clauses use.
      expressionRow table bound e =
        let (outer, regions) = splitHandled e
            names = nub [x | x <- exprVars outer, x `notElem` bound, M.member x known]
        in concatMap (rowOf table) names ++ concat
             [ [a | a <- expressionRow table bound inner, Just a /= handlerInstance h] ++ concatMap (rowOf table) (handlerClauseNames h)
             | (h, inner) <- regions ]
      raises d = "prelude.raise" `elem` exprVars (functionBody d)
  -- Rows: the least fixed point over the call graph.
  forM_ definitions $ \d -> when (raises d && null (failures (functionName d)))
    (Left (at (functionSpan d), functionName d ++ " raises a failure, so its signature must say what it fails with: add `fails with` and the failure's type"))
  forM_ definitions $ \d -> when ("prelude.attempt" `elem` exprVars (functionBody d))
    (Left (at (functionSpan d), functionName d ++ ": prelude.attempt is for laws, for now"))
  forM_ [(d, h) | d <- definitions, (h, _) <- snd (splitHandled (functionBody d))] $ \(d, h) ->
    unless (M.member (unqualifiedHandler h) handlerTable)
      (Left (at (functionSpan d), functionName d ++ " handles with " ++ h ++ ", but there is no handler called " ++ unqualifiedHandler h))
  let step table = M.fromList
        [ (functionName d, canonical (expressionRow table (map fst (functionArguments d)) (functionBody d) ++
            (if raises d then failures (functionName d) else [])))
        | d <- definitions ]
      solve table = let next = step table in if next == table then table else solve next
      inferred = solve (M.fromList [(functionName d, []) | d <- definitions])
      -- A parameterized ability used at several types: inferred rows hold
      -- them all, so a definition that uses it must say which.
      several inst = case M.lookup (abilityTypeName inst) byName of
        Just a -> length (instancesOf a) > 1
        Nothing -> False
      finalRow n = case declaredRow n of
        Just row -> row
        Nothing -> rowOf inferred n
  forM_ definitions $ \d -> do
    let row = M.findWithDefault [] (functionName d) inferred
        where' = at (functionSpan d)
    case M.lookup (functionName d) clauseOwner of
      Just h | handlerAbility h `elem` row -> Left (where', "the handler clause " ++ functionName d ++ " uses " ++
        prettyType (handlerAbility h) ++ ", the ability its handler handles; a clause may use other abilities only")
      _ -> pure ()
    case declaredRow (functionName d) of
      Nothing -> forM_ (nub [abilityTypeName i | i <- row, several i]) $ \n ->
        Left (where', functionName d ++ " uses " ++ n ++ ", which this unit uses at more than one type; say which with `uses " ++ n ++ " T`")
      Just listed -> forM_ row $ \ability -> unless (ability `elem` listed || (several ability && any ((== abilityTypeName ability) . abilityTypeName) listed)) $ do
        let through = [r | r <- exprVars (functionBody d), M.member r known, ability `elem` rowOf inferred r]
        Left (where', functionName d ++ " uses " ++ prettyType ability ++
          (case through of r : _ -> " (through " ++ r ++ ")"; [] -> "") ++
          ", but its uses list does not say so; add " ++ prettyType ability ++ " to it")
  let rows = [(n, finalRow n) | n <- map fst (functions u) ++ clauseNames, n `M.notMember` operationAbility, not (null (finalRow n))]
      rowTable = M.fromList rows
      nameRow n = maybe (M.findWithDefault [] n rowTable) id (if M.member n operationAbility then Just (opInstances n) else Nothing)
      defaults inst
        | abilityTypeName inst == failAbilityName = [ChooseProduction]
        | otherwise = ChooseProduction : [ChooseSpec (handlerName h) | h <- handlerDeclarations u, handlerAbility h == inst]
      lawTable = M.fromList [(lawName l, l) | l <- laws u]
      -- The abilities a law needs: everything its clauses and examples call,
      -- through the laws it invokes.
      lawRow seen l =
        let own = canonical (concat [expressionRowNames (bound' l) e | e <- lawExpressions l] ++
              concatMap opInstances (countedOperations l))
            invoked = [i | n <- invokedNames (definition l), n `notElem` seen, Just i <- [M.lookup n lawTable]]
        in canonical (own ++ concatMap (lawRow (lawName l : seen)) invoked)
      bound' l = map fst (parameters l) ++ quantifiedNames (definition l)
      expressionRowNames bound e =
        let (outer, regions) = splitHandled e
        in concatMap nameRow (nub [x | x <- exprVars outer, x `notElem` bound, M.member x known]) ++ concat
             [ [a | a <- expressionRowNames bound inner, Just a /= handlerInstance h] ++ concatMap nameRow (handlerClauseNames h)
             | (h, inner) <- regions ]
      handlerAbilities = M.fromList [(handlerName h, handlerAbility h) | h <- handlerDeclarations u]
      -- What `using` asks for, by ability name.
      request where' use = case use of
        UseHandler h -> case M.lookup (unqualifiedHandler h) handlerAbilities of
          Just inst -> pure (inst, Left (ChooseSpec (unqualifiedHandler h)))
          Nothing -> Left (where', "there is no handler called " ++ h)
        UseAbility n
          | M.member (unqualifiedHandler n) byName -> pure (Named (unqualifiedHandler n), Right False)
          | otherwise -> Left (where', "there is no ability called " ++ n)
        UseRecording (UseRecording _) -> Left (where', "recording a recording is not supported")
        UseRecording inner -> do
          (n, r) <- request where' inner
          when (abilityTypeName n == failAbilityName) (Left (where', "Fail cannot be recorded"))
          pure (n, either (Left . ChooseRecording) (const (Right True)) r)
      choicesFor l = do
        let where' = Just (location l)
            row = lawRow [] l
        requested <- mapM (request where') (maybe [] id (lookup (lawName l) (lawHandlers u)))
        -- A spec handler names one instance; an ability's name, all of them.
        let matches (wanted, _) inst = case wanted of
              Named n | n == abilityTypeName inst -> True
              _ -> wanted == inst
        forM_ requested $ \r@(n, _) -> do
          when (length (filter (\(m, _) -> m == n) requested) > 1)
            (Left (where', "the law " ++ lawName l ++ " names two handlers for " ++ prettyType n))
          unless (any (matches r) row)
            (Left (where', "the law " ++ lawName l ++ " names a handler for " ++ prettyType n ++ ", but nothing it calls uses " ++ prettyType n))
        let candidates inst = case [r | (_, r) <- filter (`matches` inst) requested] of
              Left c : _ -> [c]
              Right recorded : _ -> (if recorded then map ChooseRecording else id) (defaults inst)
              [] -> defaults inst
        forM_ (countedOperations l) $ \op -> case M.lookup op operationAbility of
          Nothing -> Left (where', "calls of " ++ op ++ ": " ++ op ++ " is not an ability operation")
          Just a -> forM_ (instancesOf a) $ \inst -> unless (all recording (candidates inst))
            (Left (where', "the law " ++ lawName l ++ " counts calls of " ++ op ++ ", so it needs a recording handler: add `using recording " ++
              abilityName a ++ "` (or `recording` and a handler's name)"))
        pure [(inst, candidates inst) | inst <- row]
      variants l choices
        | null choices = [(l, [])]
        | otherwise =
            let base = [(inst, head cs) | (inst, cs) <- choices]
                others = [[(i, if i == inst then c else b) | (i, b) <- base] | (inst, cs) <- choices, c <- drop 1 cs]
                assignments = base : others
            in if length assignments == 1 then [(l, close base)]
               else [(l { lawName = lawName l ++ " " ++ describeChoices a }, close a) | a <- assignments]
      -- A spec handler whose clauses use abilities needs handlers for them
      -- too: the first lawful one of each.
      close assignment =
        let needed = canonical [i | (_, c) <- assignment, h <- specOf c, n <- handlerClauseNames h, i <- nameRow n]
            missing = [i | i <- needed, i `notElem` map fst assignment]
        in if null missing then assignment else close (assignment ++ [(i, head (defaults i)) | i <- missing])
      specOf c = case c of
        ChooseSpec h -> [h]
        ChooseRecording inner -> specOf inner
        ChooseProduction -> []
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
  -- Ability laws, and the laws an operation's refined type implies: one per
  -- instance and handler.
  abilityLawCopies <- fmap concat $ forM declared $ \a -> fmap concat $ forM (instancesOf a) $ \inst -> do
    let table = zip (abilityParameters a) (abilityArguments inst)
        implied = refinementLaws a inst
    fmap concat $ forM (map (instantiateLaw table) (abilityLaws a) ++ implied) $ \l -> do
      unless (null (parameters l))
        (Left (Just (location l), "an ability's laws must be closed: quantify their values with `for all`"))
      let row = lawRow [] l
          others = [(i, head (defaults i)) | i <- row, i /= inst]
      pure [ (l { lawName = prettyType inst ++ ": " ++ lawName l ++ " " ++ describeChoices [(inst, c)] }, close ((inst, c) : others))
           | c <- defaults inst, ownHandler a c ]
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
    -- An ability's laws are checked where each handler is declared: the
    -- native one with the ability, a spec handler in its unit.
    ownHandler a c = case c of
      ChooseProduction -> null (abilityOrigin a)
      ChooseSpec h -> any (\d -> handlerName d == h && null (handlerOrigin d)) (handlerDeclarations u)
      ChooseRecording inner -> ownHandler a inner
    canonical = sortOn prettyType . nub
    lawExpressions l = definitionExpressions (definition l) ++ concat [map actual (expectations e) | e <- examples l]
    quantifiedNames d = case d of
      Forall qs body -> map fst qs ++ quantifiedNames body
      Implies _ body -> quantifiedNames body
      And a b -> quantifiedNames a ++ quantifiedNames b
      _ -> []

-- The type variable an ability's parameter becomes in its operations' types;
-- LawSpec.Inference instantiates it afresh at each use.
abilityVariable :: String -> String -> String
abilityVariable ability parameter = "ability:" ++ ability ++ ":" ++ parameter

-- A law of a parameterized ability, at one instance.
instantiateLaw :: [(String, Type)] -> Law -> Law
instantiateLaw [] l = l
instantiateLaw table l = l { definition = go (definition l) }
  where
    ty = mapType (\t -> case t of Variable v -> maybe t id (lookup v table); _ -> t) (mapExprTypes ty)
    expr = mapExprTypes ty
    go d = case d of
      Forall qs body -> Forall [(n, ty t) | (n, t) <- qs] (go body)
      Equal a b -> Equal (expr a) (expr b)
      Holds a -> Holds (expr a)
      Implies a body -> Implies (expr a) (go body)
      And a b -> And (go a) (go b)
      Invoke n args -> Invoke n (map expr args)

-- An operation whose result type is refined owes its results that
-- refinement, from every handler, for arguments that keep theirs.
refinementLaws :: AbilityDeclaration -> Type -> [Law]
refinementLaws a inst =
  [ Law (op ++ " gives what its type says") [] [] claim "" "" [] [] (Location "<ability>" (line (abilitySpan a)) 1)
  | (op, ty) <- instantiatedOperations a inst
  , let (arguments, result) = functionType ty
        values = ["value" ++ show i | i <- [0 .. length arguments - 1]]
        call = foldl Apply (Var op) (map Var values)
        predicates = typePredicates call result
  , not (null predicates)
  , let body = Holds (foldr1 (Binary "&&") predicates)
        claim = if null values then body else Forall (zip values arguments) body ]
  where line (Span (Location _ l _) _) = l

-- A clause of a handler with state s: `~s := e;` statements, then the
-- result. Each statement sees the state the ones before it left. The clause
-- gives Pair result state. (`;` before a non-flow statement is a let, so a
-- clause may also order the operations it performs.)
stateful :: Maybe Location -> String -> Expr -> Either Failure Expr
stateful at state = go (Var state)
  where
    go current e = case unlocated e of
      Binary ";" first rest -> case unlocated first of
        Binary ":=" target value | unlocated target == Var ('~' : state) -> go (replace current value) rest
        _ -> Left (at, "in a handler clause, only `~" ++ state ++ " := value;` may come before the result")
      Binary ":=" _ _ -> Left (at, "a handler clause ends with its result, after `~" ++ state ++ " := value;`")
      MatchExpr value [MatchBranch tag [name] rest] | tag == letTag -> do
        rest' <- go current rest
        pure (MatchExpr (replace current value) [MatchBranch tag [name] rest'])
      _ -> do
        let result = replace current e
        when ("Var \"~" `isInfixOf` show result) (Left (at, "~" ++ state ++ " may appear only on the left of :="))
        pure (ConstructLit pairConstructor [result, current])
    replace current = replaceExprVars [(state, current)]

-- Pair, as a unit names it once its imports are resolved.
pairType, pairConstructor :: String
pairType = collectionsUnit ++ "::type::Pair"
pairConstructor = pairType ++ "::Pair"

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

-- The handle ... with h end regions of an expression, and the rest of it.
splitHandled :: Expr -> (Expr, [(String, Expr)])
splitHandled e = case e of
  Located r inner -> let (o, rs) = splitHandled inner in (Located r o, rs)
  Apply (Var name) body | Just h <- handledBy name -> (BoolLit True, [(h, body)])
  Apply (Located _ (Var name)) body | Just h <- handledBy name -> (BoolLit True, [(h, body)])
  Apply f x -> both Apply f x
  Compose f x -> both Compose f x
  Binary op a b -> both (Binary op) a b
  Unary op a -> let (o, rs) = splitHandled a in (Unary op o, rs)
  Annotate a t -> let (o, rs) = splitHandled a in (Annotate o t, rs)
  ConstructLit n fields -> let parts = map splitHandled fields in (ConstructLit n (map fst parts), concatMap snd parts)
  ListLit xs -> let parts = map splitHandled xs in (ListLit (map fst parts), concatMap snd parts)
  MatchExpr v branches ->
    let (o, rs) = splitHandled v
        parts = [(MatchBranch tag names b', bs) | MatchBranch tag names body <- branches, let (b', bs) = splitHandled body]
    in (MatchExpr o (map fst parts), rs ++ concatMap snd parts)
  AllElementsExpr v b p -> let (o, rs) = splitHandled v; (p', ps) = splitHandled p in (AllElementsExpr o b p', rs ++ ps)
  _ -> (e, [])
  where
    both k a b = let (oa, ra) = splitHandled a; (ob, rb) = splitHandled b in (k oa ob, ra ++ rb)

definitionExpressions :: Definition -> [Expr]
definitionExpressions d = case d of
  Forall _ body -> definitionExpressions body
  Equal a b -> [a, b]
  Holds a -> [a]
  Implies a body -> a : definitionExpressions body
  And a b -> definitionExpressions a ++ definitionExpressions b
  Invoke _ args -> args

invokedNames :: Definition -> [String]
invokedNames d = case d of
  Forall _ body -> invokedNames body
  Implies _ body -> invokedNames body
  And a b -> invokedNames a ++ invokedNames b
  Invoke n _ -> [n]
  _ -> []

-- The operations a law counts with `calls of`.
countedOperations :: Law -> [String]
countedOperations l = nub (concatMap counted (definitionExpressions (definition l)))
  where
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
