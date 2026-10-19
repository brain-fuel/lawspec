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
import Data.Char (toUpper, isLower, isAlphaNum)
import Data.List (intercalate, isInfixOf, nub, sortOn)
import qualified Data.Map.Strict as M
import LawSpec.Model
import LawSpec.Collections (collectionsUnit)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Temporal (budgetStart)
import LawSpec.Builtins (isSeededUse, seededHandler, seededHandlerName, randomAbility, secureRandomAbility)

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
describeChoices assignment = "[" ++ intercalate ", " (nub (map describe named)) ++ "]"
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
elaborateAbilities u0
  | not (usesAbilities u0) = pure u0
  | otherwise = do
      u <- seededHandlers u0
      secureRandomChecks u
      elaborateUnit u

elaborateUnit :: Unit -> Either Failure Unit
elaborateUnit u0 = do
  -- A start value that computes (prelude.keyValOf [], emptyLog unitValue)
  -- becomes a checked definition of its own, <handler>Start, so it is
  -- typed, proved and specialized like a clause, and each target makes a
  -- handler's state by calling it.
  let computed e = any (\v -> take 1 v /= "~") (exprVars e)
      startName h = handlerName h ++ "Start"
      startDefinitions =
        [ FunctionDefinition (startName h) [("lawspecUnit", Named "Unit")] ty [] start (handlerSpan h)
        | h <- handlerDeclarations u0, Just (_, ty, start) <- [handlerState h], computed start ]
      u = u0 { handlerDeclarations =
                 [ h { handlerState = fmap (\(s, ty, start) -> (s, ty, if computed start
                         then Apply (Var (startName h)) (ScalarLit (SAbsent "Unit")) else start)) (handlerState h) }
                 | h <- handlerDeclarations u0 ]
             , functionDefinitions = functionDefinitions u0 ++ startDefinitions
             , functions = functions u0 ++ [(functionName d, Arrow (Named "Unit") (functionResult d)) | d <- startDefinitions]
             , declarationSpans = declarationSpans u0 ++ [(functionName d, functionSpan d) | d <- startDefinitions] }
  forM_ startDefinitions $ \d -> when (functionName d `elem` map fst (functions u0))
    (Left (Just (spanStart (functionSpan d)), "the start value of a handler would be the definition " ++ functionName d ++ ", which already exists"))
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
  forM_ declared $ \a -> forM_ (abilityFailures a) $ \(op, _) ->
    when (length (filter ((== op) . fst) (abilityFailures a)) > 1)
      (Left (at (abilitySpan a), "the operation " ++ op ++ " says twice what it fails with"))
  forM_ (handlerDeclarations u) $ \h -> do
    mapM_ (checkAbilityType (at (handlerSpan h))) (handlerAbilities h)
    when (length (nub (map abilityTypeName (handlerAbilities h))) < length (handlerAbilities h))
      (Left (at (handlerSpan h), "the handler " ++ handlerName h ++ " names an ability twice"))
  -- Instances: each type an ability is used at, as uses lists and handlers
  -- name them. An ability without parameters has one.
  let mentioned = concatMap snd (declaredUses u) ++ concatMap handlerAbilities (handlerDeclarations u)
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
      -- An operation that `fails with E` adds Fail E to the row of what
      -- performs it, and lets its clauses raise E.
      opFailures op = case M.lookup op operationAbility of
        Just a -> [Applied failAbilityName t | (o, t) <- abilityFailures a, o == op]
        Nothing -> []
      handlerInstance name = handlerAbility <$> M.lookup (unqualifiedHandler name) handlerTable
  -- Spec handlers: one checked definition per clause.
  clauseDefinitions <- fmap concat $ forM (handlerDeclarations u) $ \h -> do
    let where' = at (handlerSpan h)
        abilityTy = handlerAbility h
        handled = intercalate ", " (map prettyType (handlerAbilities h))
    forM_ (handlerAbilities h) $ \ty -> when (abilityTypeName ty == failAbilityName)
      (Left (where', "Fail's handler is built in; handlers for Fail are not supported yet"))
    answered <- forM (handlerAbilities h) $ \ty ->
      maybe (Left (where', "there is no ability called " ++ abilityTypeName ty)) (\a -> Right (a, ty)) (M.lookup (abilityTypeName ty) byName)
    when (length (filter ((== handlerName h) . handlerName) (handlerDeclarations u)) > 1)
      (Left (where', "the handler " ++ handlerName h ++ " is declared twice"))
    unless (maybe False isLower (headMaybe (handlerName h)))
      (Left (where', "handler names start with a lowercase letter"))
    let operations = concat [instantiatedOperations a ty | (a, ty) <- answered]
        clauseNames = map clauseOperation (handlerClauses h)
    forM_ (nub clauseNames) $ \c -> do
      when (length (filter (== c) clauseNames) > 1)
        (Left (where', "the handler " ++ handlerName h ++ " has two clauses for " ++ c))
      unless (c `elem` map fst operations)
        (Left (where', handled ++ (if length answered > 1 then " have" else " has") ++ " no operation called " ++ c ++ ", so " ++ handlerName h ++ " cannot handle it"))
    forM operations $ \(op, ty) -> do
      clause <- maybe (Left (where', "the handler " ++ handlerName h ++ " for " ++ handled ++
        " has no clause for " ++ op)) Right (lookup op [(clauseOperation c, c) | c <- handlerClauses h])
      let (parameters', result) = functionType ty
          name = clauseDefinitionName (handlerName h) op
          clauseAt = at (clauseSpan clause)
      -- op by f: the clause applies f to the operation's values, and to the
      -- state when the handler has one (f then gives Pair result state).
      let byTarget = case unlocated (clauseBody clause) of
            Apply f target | unlocated f == Var clauseBy -> Just target
            _ -> Nothing
          parameterNames = case byTarget of
            Just _ -> ["value" ++ show i | i <- [0 .. length parameters' - 1]]
            Nothing -> clauseParameters clause
          arguments = zip parameterNames parameters'
          values = map (Var . fst) arguments
      unless (byTarget /= Nothing || length (clauseParameters clause) == length parameters')
        (Left (clauseAt, "the clause for " ++ op ++ " in " ++ handlerName h ++ " takes " ++
          show (length parameters') ++ " value(s), as " ++ op ++ " :: " ++ prettyType ty ++ " does"))
      when (name `elem` functionNames)
        (Left (clauseAt, "the clause for " ++ op ++ " in " ++ handlerName h ++ " would be the definition " ++ name ++ ", which already exists"))
      case (handlerState h, byTarget) of
        (Nothing, _) -> pure (FunctionDefinition name
          (if null arguments then [("lawspecUnit", Named "Unit")] else arguments)
          result [] (maybe (clauseBody clause) (\f -> foldl Apply f values) byTarget) (clauseSpan clause))
        (Just (state, stateType, _), Just f) -> pure (FunctionDefinition name ((state, stateType) : arguments)
          (Application pairType [result, stateType]) [] (foldl Apply f (values ++ [Var state])) (clauseSpan clause))
        (Just (state, stateType, _), Nothing) -> do
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
      clauseFailures = M.fromList [(clauseDefinitionName (handlerName h) (clauseOperation c), opFailures (clauseOperation c))
                                  | h <- handlerDeclarations u, c <- handlerClauses h]
      failures n = [t | Just ts <- [declaredRow n], t <- ts, abilityTypeName t == failAbilityName] ++
        M.findWithDefault [] n clauseFailures
      fixedRow n
        | M.member n operationAbility = Just (opInstances n ++ opFailures n)
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
             [ if h == attemptRegion then [a | a <- expressionRow table bound inner, abilityTypeName a /= failAbilityName]
               else [a | a <- expressionRow table bound inner, Just a /= handlerInstance h] ++ concatMap (rowOf table) (handlerClauseNames h)
             | (h, inner) <- regions ]
      raises d = "prelude.raise" `elem` exprVars (functionBody d)
      declaresFailure n = not (null [t | Just ts <- [declaredRow n], t <- ts, abilityTypeName t == failAbilityName])
  -- Rows: the least fixed point over the call graph.
  forM_ definitions $ \d -> when (raises d && null (failures (functionName d)))
    (Left (at (functionSpan d), functionName d ++ " raises a failure, so its signature must say what it fails with: add `fails with` and the failure's type"))
  forM_ [(d, h) | d <- definitions, (h, _) <- snd (splitHandled (functionBody d)), h /= attemptRegion] $ \(d, h) ->
    unless (M.member (unqualifiedHandler h) handlerTable)
      (Left (at (functionSpan d), functionName d ++ " handles with " ++ h ++ ", but there is no handler called " ++ unqualifiedHandler h))
  forM_ [(d, h) | d <- definitions, (h, _) <- snd (splitHandled (functionBody d)), h /= attemptRegion] $ \(d, h) ->
    forM_ (M.lookup (unqualifiedHandler h) handlerTable) $ \hd -> unless (null (handlerAlso hd))
      (Left (at (functionSpan d), functionName d ++ " handles with " ++ h ++ ", which answers several abilities; " ++
        "`handle ... with` takes a handler of one ability, for now"))
  -- A seeded Random cannot stand for SecureRandom (LawSpec.Builtins).
  forM_ [(d, h, inner) | d <- definitions, (h, inner) <- snd (splitHandled (functionBody d)), h /= attemptRegion] $ \(d, h, inner) ->
    when (fmap abilityTypeName (handlerInstance h) == Just randomAbility &&
          any (`elem` exprVars inner) [op | a <- declared, abilityName a == secureRandomAbility, (op, _) <- abilityOperations a])
      (Left (at (functionSpan d), seededForSecure (functionName d)))
  let step table = M.fromList
        [ (functionName d, canonical (expressionRow table (map fst (functionArguments d)) (functionBody d) ++
            -- A definition that says it fails with E has Fail E in its
            -- row whether or not its body raises, so a clause `by` it does.
            (if raises d || declaresFailure (functionName d) then failures (functionName d) else [])))
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
      Just h | (a : _) <- filter (`elem` row) (handlerAbilities h) -> Left (where', "the handler clause " ++ functionName d ++ " uses " ++
        prettyType a ++ (if null (handlerAlso h) then ", the ability its handler handles" else ", an ability its handler handles") ++
        "; a clause may use other abilities only")
      -- A clause fails only as its operation says it may.
      Just h | (f : _) <- [t | t <- row, abilityTypeName t == failAbilityName, t `notElem` M.findWithDefault [] (functionName d) clauseFailures] ->
        Left (where', "the handler clause " ++ functionName d ++ " of " ++ handlerName h ++ " may fail with " ++
          prettyType (headType f) ++ ", but its operation does not say so; add `fails with " ++ prettyType (headType f) ++ "` to the operation")
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
      nameRow n = maybe (M.findWithDefault [] n rowTable) id (if M.member n operationAbility then Just (opInstances n ++ opFailures n) else Nothing)
      defaults inst
        | abilityTypeName inst == failAbilityName = [ChooseProduction]
        | otherwise = ChooseProduction : [ChooseSpec (handlerName h) | h <- handlerDeclarations u, inst `elem` handlerAbilities h]
      lawTable = M.fromList [(lawName l, l) | l <- laws u]
      -- The abilities a law needs: everything its clauses and examples call,
      -- through the laws it invokes.
      lawRow seen l =
        let scope = map fst (parameters l) ++ map fst (lawResources l)
            own = canonical (definitionRow scope (definition l) ++
              concat [expressionRowNames (map fst (bindings example) ++ scope) (actual check)
                | example <- examples l, check <- expectations example] ++
              concatMap opInstances (countedOperations l))
            invoked = [i | n <- invokedNames (definition l), n `notElem` seen, Just i <- [M.lookup n lawTable]]
        in canonical (own ++ concatMap (lawRow (lawName l : seen)) invoked)
      definitionRow scope definition = case definition of
        Forall qs body -> definitionRow (map fst qs ++ scope) body
        Exists qs body -> definitionRow (map fst qs ++ scope) body
        Not body -> definitionRow scope body
        Equal a b -> expressionRowNames scope a ++ expressionRowNames scope b
        Holds a -> expressionRowNames scope a
        Implies guard body -> expressionRowNames scope guard ++ definitionRow scope body
        And a b -> definitionRow scope a ++ definitionRow scope b
        Invoke _ arguments -> concatMap (expressionRowNames scope) arguments
      expressionRowNames bound e =
        let (outer, regions) = splitHandled e
        in concatMap nameRow (nub [x | x <- exprVars outer, x `notElem` bound, M.member x known]) ++ concat
             [ if h == attemptRegion then [a | a <- expressionRowNames bound inner, abilityTypeName a /= failAbilityName]
               else [a | a <- expressionRowNames bound inner, Just a /= handlerInstance h] ++ concatMap nameRow (handlerClauseNames h)
             | (h, inner) <- regions ]
      -- Resource callbacks normally use production handlers (Frontend). A
      -- law can explicitly select a handler they need, even if its assertion
      -- never calls that ability. Local release/reset binders can shadow an
      -- operation name and must not create a spurious ability requirement.
      resourceRow l = canonical $ concat
        [ expressionRowNames [] (resourceAcquire r) ++
          concat [expressionRowNames [binder] body
            | (binder, body) <- resourceRelease r : maybe [] pure (resourceReset r)]
        | (_, ty) <- lawResources l, r <- resourceDeclarations u, resourceType r == ty ]
      handlerAbilityTable = M.fromList [(handlerName h, handlerAbilities h) | h <- handlerDeclarations u]
      -- What `using` asks for, by ability name. A handler of several
      -- abilities, or a set of handlers, asks for each that the law uses.
      request row where' use = case use of
        UseHandler h | Just _ <- isSeededUse h -> Left (where', "seeded random needs lawspec.randomness: add `import lawspec.randomness`")
        UseHandler h | Just set <- lookup (unqualifiedHandler h) [(handlerSetName s, s) | s <- handlerSets u] ->
          case [(inst, Left (ChooseSpec member)) | (inst, member) <- setCoverage set, inst `elem` row] of
            [] -> Left (where', "the handlers " ++ h ++ " answer nothing the law uses")
            chosen -> pure chosen
        UseHandler h -> case M.lookup (unqualifiedHandler h) handlerAbilityTable of
          Just [inst] -> pure [(inst, Left (ChooseSpec (unqualifiedHandler h)))]
          Just insts -> case [(inst, Left (ChooseSpec (unqualifiedHandler h))) | inst <- insts, inst `elem` row] of
            [] -> pure [(head insts, Left (ChooseSpec (unqualifiedHandler h)))]
            chosen -> pure chosen
          Nothing -> Left (where', "there is no handler called " ++ h)
        UseAbility n
          | M.member (unqualifiedHandler n) byName -> pure [(Named (unqualifiedHandler n), Right False)]
          | otherwise -> Left (where', "there is no ability called " ++ n)
        UseRecording (UseRecording _) -> Left (where', "recording a recording is not supported")
        UseRecording inner -> do
          chosen <- request row where' inner
          forM chosen $ \(n, r) -> do
            when (abilityTypeName n == failAbilityName) (Left (where', "Fail cannot be recorded"))
            pure (n, either (Left . ChooseRecording) (const (Right True)) r)
      choicesFor l = do
        let where' = Just (location l)
            assertionRow = lawRow [] l
            resources = resourceRow l
            available = canonical (assertionRow ++ resources)
        requested <- concat <$> mapM (request available where') (maybe [] id (lookup (lawName l) (lawHandlers u)))
        -- A spec handler names one instance; an ability's name, all of them.
        let matches (wanted, _) inst = case wanted of
              Named n | n == abilityTypeName inst -> True
              _ -> wanted == inst
            row = available
        forM_ requested $ \r@(n, _) -> do
          when (abilityTypeName n == randomAbility && Named secureRandomAbility `elem` available && Named randomAbility `notElem` available)
            (Left (where', seededForSecure ("the law `" ++ lawName l ++ "`")))
          when (length (filter (\(m, _) -> m == n) requested) > 1)
            (Left (where', "the law " ++ lawName l ++ " names two handlers for " ++ prettyType n))
          unless (any (matches r) available)
            (Left (where', "the law " ++ lawName l ++ " names a handler for " ++ prettyType n ++ ", but nothing it calls uses " ++ prettyType n))
        budgetClock where' l requested
        let candidates inst = measuredOn l inst $ case [r | (_, r) <- filter (`matches` inst) requested] of
              Left c : _ -> [c]
              Right recorded : _ -> (if recorded then map ChooseRecording else id) (defaults inst)
              [] -> if inst `elem` assertionRow then defaults inst else [ChooseProduction]
        forM_ (countedOperations l) $ \op -> case M.lookup op operationAbility of
          Nothing -> Left (where', "calls of " ++ op ++ ": " ++ op ++ " is not an ability operation")
          Just a -> forM_ (instancesOf a) $ \inst -> unless (all recording (candidates inst))
            (Left (where', "the law " ++ lawName l ++ " counts calls of " ++ op ++ ", so it needs a recording handler: add `using recording " ++
              abilityName a ++ "` (or `recording` and a handler's name)"))
        let pinned = [inst | (wanted, Left _) <- requested, inst <- row, matches (wanted, ()) inst]
        pure ([(inst, candidates inst) | inst <- row], pinned)
      variants l (choices, pinned)
        | null choices = [(l, [])]
        | otherwise =
            let base = [(inst, head cs) | (inst, cs) <- choices]
                others = [[(i, if i == inst then c else b) | (i, b) <- base] | (inst, cs) <- choices, c <- drop 1 cs]
                assignments = nub (map (cohere pinned) (base : others))
                -- A set of handlers that answers some of the law's
                -- abilities: the law also runs under all of them at once.
                sets = [ (set, a) | set <- handlerSets u
                       , let a = cohere pinned [(i, if i `elem` pinned then c else maybe c (\h -> recordedAs c (ChooseSpec h)) (lookup i (setCoverage set))) | (i, c) <- base]
                       , a `notElem` assignments ]
            in if length assignments == 1 && null sets then [(l, close [] (head assignments))]
               else [(l { lawName = lawName l ++ " " ++ describeChoices a }, close [] a) | a <- assignments] ++
                    [(l { lawName = lawName l ++ " [" ++ handlerSetName set ++ "]" }, close (setCoverage set) a) | (set, a) <- sets]
      -- A spec handler whose clauses use abilities needs handlers for them
      -- too: the set's, a handler of several abilities already chosen, or
      -- else the first lawful one of each.
      close preferred assignment =
        let needed = canonical [i | (_, c) <- assignment, h <- specOf c, n <- handlerClauseNames h, i <- nameRow n]
            missing = [i | i <- needed, i `notElem` map fst assignment]
            chosenFor i = case lookup i preferred of
              Just h -> ChooseSpec h
              Nothing -> case [ChooseSpec h | (_, c) <- assignment, h <- specOf c, Just insts <- [M.lookup h handlerAbilityTable], i `elem` insts] of
                c : _ -> c
                [] -> head (defaults i)
        in if null missing then assignment else close preferred (assignment ++ [(i, chosenFor i) | i <- missing])
      -- A handler of several abilities answers all of them from one state:
      -- chosen for one, it is chosen for the others the law leaves open.
      cohere pinned assignment =
        let shared = [(inst, h) | (_, c) <- assignment, h <- specOf c, Just insts <- [M.lookup h handlerAbilityTable], length insts > 1, inst <- insts]
        in [ (i, case (c, lookup i shared) of
                   (_, Just h) | i `notElem` pinned, null (specOf c) -> recordedAs c (ChooseSpec h)
                   _ -> c)
           | (i, c) <- assignment ]
      recordedAs c inner = case c of
        ChooseRecording _ -> ChooseRecording inner
        _ -> inner
      setCoverage set = [(inst, member) | member <- handlerSetMembers set, Just insts <- [M.lookup (unqualifiedHandler member) handlerAbilityTable], inst <- insts]
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
        RecordLit fields -> RecordLit <$> mapM (\(label,value) -> (,) label <$> attemptIn where' value) fields
        ListLit xs -> ListLit <$> mapM (attemptIn where') xs
        MatchExpr v branches -> MatchExpr <$> attemptIn where' v <*>
          mapM (\(MatchBranch tag names body) -> MatchBranch tag names <$> attemptIn where' body) branches
        _ -> pure e
        where
          attempted body = do
            body' <- attemptIn where' body
            case failuresOf body' of
              [Applied _ failure] -> pure (Annotate (Apply (Var "prelude.attempt") body')
                (Application "Either" [failure, Variable ("attempt:" ++ show (spanKey where') ++ ":" ++ take 16 (digestHex (digestString (prettyExpr body'))))]))
              [] -> Left (where', "prelude.attempt: nothing in " ++ prettyExpr body' ++ " can fail")
              many -> Left (where', "prelude.attempt: " ++ prettyExpr body' ++ " can fail in more than one way (" ++
                intercalate ", " (map prettyType many) ++ ")")
      spanKey where' = maybe 0 (\(Location _ line column) -> line * 1000 + column) where'
      attemptLaw l = do
        let where' = Just (location l)
            go d = case d of
              Forall bound body -> Forall bound <$> go body
              Exists bound body -> Exists bound <$> go body
              Not body -> Not <$> go body
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
  -- A definition may attempt too: its failure type comes the same way.
  -- Its type names no variable, so the failure's type is given on Left.
  let typedAttempts e = case e of
        Located r inner -> Located r (typedAttempts inner)
        Annotate (Apply (Var "prelude.attempt") body) (Application "Either" [failure, _]) ->
          MatchExpr (Apply (Var "prelude.attempt") (typedAttempts body))
            [ MatchBranch "Either::Left" ["lawspecFailure"] (ConstructLit "Either::Left" [Annotate (Var "lawspecFailure") failure])
            , MatchBranch "Either::Right" ["lawspecValue"] (ConstructLit "Either::Right" [Var "lawspecValue"]) ]
        Apply f x -> Apply (typedAttempts f) (typedAttempts x)
        Binary op a b -> Binary op (typedAttempts a) (typedAttempts b)
        Unary op a -> Unary op (typedAttempts a)
        Annotate a t -> Annotate (typedAttempts a) t
        ConstructLit n fields -> ConstructLit n (map typedAttempts fields)
        RecordLit fields -> RecordLit [(label,typedAttempts value) | (label,value) <- fields]
        ListLit xs -> ListLit (map typedAttempts xs)
        MatchExpr v branches -> MatchExpr (typedAttempts v) [MatchBranch tag names (typedAttempts b) | MatchBranch tag names b <- branches]
        _ -> e
  attemptedDefinitions <- forM definitions $ \d -> (\b -> d { functionBody = typedAttempts b }) <$> attemptIn (at (functionSpan d)) (functionBody d)
  -- Ordinary laws: concrete ones get their handlers; generic ones are
  -- templates, instantiated where they are invoked.
  expandedLaws <- fmap concat $ forM attemptedLaws $ \l ->
    if not (null (parameters l)) then pure [(l, [])] else variants l <$> choicesFor l
  -- Ability laws, and the laws an operation's refined type implies: one per
  -- instance and handler.
  abilityLawCopies <- fmap concat $ forM declared $ \a -> fmap concat $ forM (instancesOf a) $ \inst -> do
    let table = zip (abilityParameters a) (abilityArguments inst)
        implied = refinementLaws a inst
    attemptedAbilityLaws <- mapM attemptLaw (map (instantiateLaw table) (abilityLaws a) ++ implied)
    fmap concat $ forM attemptedAbilityLaws $ \l -> do
      unless (null (parameters l))
        (Left (Just (location l), "an ability's laws must be closed: quantify their values with `for all`"))
      let row = lawRow [] l
          others = [(i, head (defaults i)) | i <- row, i /= inst]
      pure [ (l { lawName = prettyType inst ++ ": " ++ lawName l ++ " " ++ describeChoices [(inst, c)] }, close [] (cohere [inst] ((inst, c) : others)))
           | c <- defaults inst, ownHandler a c ]
  -- Each set of handlers owes the laws of every ability it answers, run
  -- under all of its handlers at once: `Broker: law [reference]`.
  setLawCopies <- fmap concat $ forM (handlerSets u) $ \set -> do
    let where' = at (handlerSetSpan set)
    forM_ (handlerSetMembers set) $ \member -> unless (M.member (unqualifiedHandler member) handlerAbilityTable)
      (Left (where', "the handlers " ++ handlerSetName set ++ " name " ++ member ++ ", which is not a handler"))
    let covered = map fst (setCoverage set)
    forM_ covered $ \inst -> when (length (filter (== inst) covered) > 1)
      (Left (where', "the handlers " ++ handlerSetName set ++ " name two handlers for " ++ prettyType inst))
    when (handlerSetName set `M.member` handlerAbilityTable || length (filter ((== handlerSetName set) . handlerSetName) (handlerSets u)) > 1)
      (Left (where', "the handlers " ++ handlerSetName set ++ " have the name of another handler or set of handlers"))
    fmap concat $ forM (setCoverage set) $ \(inst, member) -> case M.lookup (abilityTypeName inst) byName of
      Nothing -> pure []
      Just a -> do
        let table = zip (abilityParameters a) (abilityArguments inst)
        attemptedAbilityLaws <- mapM attemptLaw (map (instantiateLaw table) (abilityLaws a) ++ refinementLaws a inst)
        pure [ (l { lawName = prettyType inst ++ ": " ++ lawName l ++ " [" ++ handlerSetName set ++ "]" }
               , close (setCoverage set) [(i, maybe (head (defaults i)) ChooseSpec (lookup i (setCoverage set))) | i <- nub (inst : lawRow [] l)])
             | l <- attemptedAbilityLaws, null (parameters l)
             , let _ = member ]
  -- ability A with T: a law that runs A's native handler takes a T, which
  -- each case acquires and every native handler made with a T shares.
  forM_ declared $ \a -> forM_ (abilityResource a) $ \t ->
    unless (any ((== t) . resourceType) (resourceDeclarations u) || null (abilityOrigin a) == False)
      (Left (at (abilitySpan a), "the ability " ++ abilityName a ++ " is made with " ++ prettyType t ++
        ", which needs a resource declaration: resource " ++ prettyType t ++ " is acquire is ... end release r is ... end end"))
  let withResources (l, assignment) =
        let natives = [inst | (inst, c) <- assignment, native c]
            needed = nub [t | inst <- natives, Just a <- [M.lookup (abilityTypeName inst) byName], Just t <- [abilityResource a]]
            missing = [t | t <- needed, t `notElem` map snd (lawResources l)]
        in (l { lawResources = lawResources l ++ [("lawspecWith" ++ filter isAlphaNum (prettyType t), t) | t <- missing] }, assignment)
      native c = case c of
        ChooseProduction -> True
        ChooseRecording inner -> native inner
        ChooseSpec _ -> False
      -- A set's copy that runs as another copy already does is left out.
      baseName name = takeWhile (/= '[') name
      -- Native handlers made with one resource are one system: a law runs
      -- them all natively or none of them, so no variant mixes a native
      -- handler made with T with a spec handler of another ability made
      -- with T (unless the law names both with `using`).
      resourceOf inst = M.lookup (abilityTypeName inst) byName >>= abilityResource
      coherent (l, assignment) =
        let named = maybe [] id (lookup (lawName l) (lawHandlers u))
            chosen = [(t, native c) | (inst, c) <- assignment, Just t <- [resourceOf inst]]
        in not (null named) || and [not (or [n | (t', n) <- chosen, t' == t] && not (and [n | (t', n) <- chosen, t' == t])) | (t, _) <- chosen]
      distinctSets = [ copy | copy@(l, a) <- setLawCopies
                     , not (any (\(l', a') -> baseName (lawName l') == baseName (lawName l) && sortOn (prettyType . fst) a' == sortOn (prettyType . fst) a) abilityLawCopies) ]
      allLaws = map withResources (filter coherent (expandedLaws ++ abilityLawCopies ++ distinctSets))
      names = map (lawName . fst) allLaws
  forM_ names $ \n -> when (length (filter (== n) names) > 1)
    (Left (Nothing, "two laws are called " ++ n ++ " once their handlers are named"))
  pure u
    { functions = functions'
    , functionDefinitions = attemptedDefinitions
    , declarationSpans = declarationSpans u ++
        [(op, abilitySpan a) | a <- declared, (op, _) <- abilityOperations a] ++
        [(functionName d, functionSpan d) | d <- clauseDefinitions]
    , laws = map fst allLaws
    , abilityRows = rows
    , lawAssignments = [(lawName l, a) | (l, a) <- allLaws, not (null a)]
    }
  where
    headMaybe xs = case xs of x : _ -> Just x; [] -> Nothing
    headType t = case abilityArguments t of x : _ -> x; [] -> t
    recording c = case c of ChooseRecording _ -> True; _ -> False
    -- An ability's laws are checked where each handler is declared: the
    -- native one with the ability, a spec handler in its unit.
    ownHandler a c = case c of
      ChooseProduction -> null (abilityOrigin a)
      ChooseSpec h -> any (\d -> handlerName d == h && null (handlerOrigin d)) (handlerDeclarations u0)
      ChooseRecording inner -> ownHandler a inner
    canonical = sortOn prettyType . nub

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
      Exists qs body -> Exists [(n, ty t) | (n, t) <- qs] (go body)
      Not body -> Not (go body)
      Equal a b -> Equal (expr a) (expr b)
      Holds a -> Holds (expr a)
      Implies a body -> Implies (expr a) (go body)
      And a b -> And (go a) (go b)
      Invoke n args -> Invoke n (map expr args)

-- An operation whose result type is refined owes its results that
-- refinement, from every handler, for arguments that keep theirs.
refinementLaws :: AbilityDeclaration -> Type -> [Law]
refinementLaws a inst =
  [ Law (op ++ " gives what its type says") [] [] claim "" "" [] [] (Location "<ability>" (line (abilitySpan a)) 1) [] emptyLawMetadata
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
-- clause may also order the operations it performs.) A `match` or an `if`
-- at the end of a clause may update the state in its branches: each branch
-- is the end of the clause, so it gives its own result and state.
stateful :: Maybe Location -> String -> Expr -> Either Failure Expr
stateful at state = go (0 :: Int) (Var state)
  where
    go depth current e
      | Just (value,checks) <- selectionValidation e = do
          value' <- go depth current value
          checks' <- mapM (\check -> case selectionBranchCheck check of
            Just body -> Apply (Var selectionBranchCheckName) <$> go depth current body
            Nothing -> plain check >> pure (replace current check)) checks
          pure (foldl Apply (Var selectionValidationName) (value':checks'))
      | otherwise = case unlocated e of
      -- This source-only fallback already denotes the complete transformed
      -- result type when independently checking an unreachable authored row.
      Var name | name == selectionBranchResultName -> pure e
      Binary ";" first rest -> case unlocated first of
        Binary ":=" target value | unlocated target == Var ('~' : state) -> do
          plain value
          go depth (replace current value) rest
        _ -> Left (at, "in a handler clause, only `~" ++ state ++ " := value;` may come before the result")
      Binary ":=" _ _ -> Left (at, "a handler clause ends with its result, after `~" ++ state ++ " := value;`")
      MatchExpr value [MatchBranch tag [name] rest] | tag == letTag -> do
        plain value
        rest' <- go depth current rest
        pure (MatchExpr (replace current value) [MatchBranch tag [name] rest'])
      -- Branches that update the state: the state so far is named first, so
      -- a branch's binders cannot capture what it reads.
      MatchExpr value branches -> do
        plain value
        named depth current $ \current' -> do
          forM_ branches $ \(MatchBranch _ names _) -> when (state `elem` names)
            (Left (at, "a match in a handler clause cannot bind the state's name, " ++ state))
          branches' <- mapM (\(MatchBranch tag names body) -> MatchBranch tag names <$> go (depth + 1) current' body) branches
          pure (MatchExpr (replace current value) branches')
      _ | Just (condition, yes, no) <- selection e -> do
        plain condition
        named depth current $ \current' -> do
          yes' <- go (depth + 1) current' yes
          no' <- go (depth + 1) current' no
          pure (foldl Apply (Var "prelude.select") [replace current condition, yes', no'])
      _ -> do
        plain e
        pure (ConstructLit pairConstructor [replace current e, current])
    replace current = replaceExprVars [(state, current)]
    plain value = when ("Var \"~" `isInfixOf` show value)
      (Left (at, "~" ++ state ++ " may appear only on the left of :=, before a clause's result or a branch's"))
    selection value = case spine value of
      (Var "prelude.select", [c, a, b]) -> Just (c, a, b)
      _ -> Nothing
    spine value = case unlocated value of
      Apply f x -> let (h, args) = spine f in (h, args ++ [x])
      other -> (other, [])
    named depth current continue = case unlocated current of
      Var _ -> continue current
      _ -> do
        let binder = "lawspecState" ++ show depth
        body <- continue (Var binder)
        pure (MatchExpr current [MatchBranch letTag [binder] body])

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

-- The region of a prelude.attempt, among the handled regions.
attemptRegion :: String
attemptRegion = ":attempt"

-- The handle ... with h end regions of an expression, and the rest of it.
splitHandled :: Expr -> (Expr, [(String, Expr)])
splitHandled e = case e of
  Located r inner -> let (o, rs) = splitHandled inner in (Located r o, rs)
  -- prelude.attempt e catches e's failures, as a handler of Fail.
  Apply (Var "prelude.attempt") body -> (BoolLit True, [(attemptRegion, body)])
  Apply (Located _ (Var "prelude.attempt")) body -> (BoolLit True, [(attemptRegion, body)])
  Apply (Var name) body | Just h <- handledBy name -> (BoolLit True, [(h, body)])
  Apply (Located _ (Var name)) body | Just h <- handledBy name -> (BoolLit True, [(h, body)])
  Apply f x -> both Apply f x
  Compose f x -> both Compose f x
  Binary op a b -> both (Binary op) a b
  Unary op a -> let (o, rs) = splitHandled a in (Unary op o, rs)
  Annotate a t -> let (o, rs) = splitHandled a in (Annotate o t, rs)
  ConstructLit n fields -> let parts = map splitHandled fields in (ConstructLit n (map fst parts), concatMap snd parts)
  RecordLit fields -> let parts = [(label,splitHandled value) | (label,value) <- fields]
    in (RecordLit [(label,value) | (label,(value,_)) <- parts],concat [uses | (_,(_,uses)) <- parts])
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
  Exists _ body -> definitionExpressions body
  Not body -> definitionExpressions body
  Equal a b -> [a, b]
  Holds a -> [a]
  Implies a body -> a : definitionExpressions body
  And a b -> definitionExpressions a ++ definitionExpressions b
  Invoke _ args -> args

invokedNames :: Definition -> [String]
invokedNames d = case d of
  Forall _ body -> invokedNames body
  Exists _ body -> invokedNames body
  Not body -> invokedNames body
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
      RecordLit fields -> concatMap (counted . snd) fields
      ListLit xs -> concatMap counted xs
      MatchExpr v branches -> counted v ++ concat [counted b | MatchBranch _ _ b <- branches]
      Compose a b -> counted a ++ counted b
      _ -> []
    spine e = case unlocated e of
      Apply f x -> let (h, args) = spine f in (h, args ++ [unlocated x])
      other -> (other, [])

-- The message for a seeded Random where SecureRandom is needed.
seededForSecure :: String -> String
seededForSecure what = what ++ " needs SecureRandom, which a seeded Random cannot answer: seeded draws are " ++
  "predictable, so the two are separate abilities. Leave SecureRandom to its default handler"

-- `seeded random n` in a law's using list names a copy of lawspec.randomness's
-- seededRandom that starts at n (LawSpec.Builtins); each seed is its own
-- handler, seededRandom<n>.
seededHandlers :: Unit -> Either Failure Unit
seededHandlers u
  | null seeds = pure u
  | otherwise = case [h | h <- handlerDeclarations u, handlerName h == seededHandler] of
      [] -> pure u
      base : _ -> pure u
        { handlerDeclarations = handlerDeclarations u ++
            [ base { handlerName = cloneName n, handlerState = fmap (\(s, t, _) -> (s, t, Number n)) (handlerState base) }
            | n <- nub seeds, cloneName n `notElem` map handlerName (handlerDeclarations u) ]
        , lawHandlers = [(n, map rename uses) | (n, uses) <- lawHandlers u]
        , functionDefinitions = [d { functionBody = renameHandles (functionBody d) } | d <- functionDefinitions u]
        , laws = map renameLaw (laws u) }
  where
    -- `using seeded random n`, and `handle e with seededRandom n end`.
    seeds = nub ([n | (_, uses) <- lawHandlers u, use <- uses, Just n <- [seeded use]] ++
      [n | e <- map functionBody (functionDefinitions u) ++ concatMap lawExpressionsOf (laws u)
         , v <- exprVars e, Just name <- [stripHandle v], Just n <- [isSeededUse name]])
    stripHandle v = if take 15 v == "prelude.handle:" then Just (drop 15 v) else Nothing
    handles = [("prelude.handle:" ++ seededHandlerName n, Var ("prelude.handle:" ++ cloneName n)) | n <- seeds]
    renameHandles = replaceExprVars handles
    lawExpressionsOf l = definitionExpressions (definition l) ++ concat [map actual (expectations ex) | ex <- examples l]
    renameLaw l = l { definition = renameDefinition (definition l)
                    , examples = [ex { expectations = [c { actual = renameHandles (actual c) } | c <- expectations ex] } | ex <- examples l] }
    renameDefinition d = case d of
      Forall bound body -> Forall bound (renameDefinition body)
      Exists bound body -> Exists bound (renameDefinition body)
      Not body -> Not (renameDefinition body)
      Equal a b -> Equal (renameHandles a) (renameHandles b)
      Holds a -> Holds (renameHandles a)
      Implies a body -> Implies (renameHandles a) (renameDefinition body)
      And a b -> And (renameDefinition a) (renameDefinition b)
      Invoke n args -> Invoke n (map renameHandles args)
    seeded use = case use of
      UseHandler h -> isSeededUse h
      UseRecording inner -> seeded inner
      UseAbility _ -> Nothing
    cloneName n = seededHandler ++ show n
    rename use = case use of
      UseHandler h | Just n <- isSeededUse h -> UseHandler (cloneName n)
      UseRecording inner -> UseRecording (rename inner)
      _ -> use

-- SecureRandom has no spec handlers: a handler written in LawSpec is
-- deterministic, so it could stand only where a seeded source may.
secureRandomChecks :: Unit -> Either Failure ()
secureRandomChecks u = forM_ (handlerDeclarations u) $ \h ->
  when (null (handlerOrigin h) && abilityTypeName (handlerAbility h) == secureRandomAbility &&
        any (\a -> abilityName a == secureRandomAbility && not (null (abilityOrigin a))) (abilities u))
    (Left (Just (spanStart (handlerSpan h)), "SecureRandom has no spec handlers: a handler written in LawSpec is predictable. " ++
      "Use Random, and seeded random n, where reproducible draws will do"))

-- A performance budget is measured on the real clock (LawSpec.Temporal): a
-- law that holds one runs under Clock's production handler only, and may
-- not name another clock.
hasBudget :: Law -> Bool
hasBudget l = ("\"" ++ budgetStart ++ "\"") `isInfixOf` show (definition l, examples l)

measuredOn :: Law -> Type -> [HandlerChoice] -> [HandlerChoice]
measuredOn l inst choices
  | hasBudget l && abilityTypeName inst == "Clock" = [ChooseProduction]
  | otherwise = choices

budgetClock :: Maybe Location -> Law -> [(Type, Either HandlerChoice Bool)] -> Either Failure ()
budgetClock where' l requested =
  when (hasBudget l && any (\(n, r) -> abilityTypeName n == "Clock" && either (const True) id r) requested)
    (Left (where', "the law `" ++ lawName l ++ "` has a budget (takes at most), which is measured on the real clock; it cannot name another clock"))
