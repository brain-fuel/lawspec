-- | Cross-unit imports, resolved after parsing and before refinement lowering, so
-- that Core and all eight backends are unchanged.
--
-- Data types stay with the unit that declares them: an imported type or
-- constructor becomes the declaring unit's qualified name, which the global
-- data registry already knows. Refinements, checked definitions and generic
-- laws are copied into the importing unit, together with everything they use,
-- under names derived from the declaring unit, so two units may declare the
-- same names. Adapter signatures and concrete laws belong to their unit and
-- are not importable.
module LawSpec.Imports (resolveImports, importedDefinitionName) where

import LawSpec.Model
import LawSpec.Indexed (naturalRefinementName)
import LawSpec.Collections (collectionsUnit, collectionsAlias, collectionOperation, internalConstructor)
import LawSpec.Time (timeUnit, timeAlias, timeOperation, durationDefinitions)
import LawSpec.Matchers (matchersUnit, matchersAlias, matcherOperation)
import LawSpec.Resources (resourcesUnit)
import LawSpec.Resilience (resilienceUnit, resilienceDefinitions)
import LawSpec.Builtins (instantDefinitions)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (State, execState, modify)
import Data.Char (toUpper)
import Data.Functor.Identity (Identity(..))
import Data.List (intercalate, isSuffixOf, nub, stripPrefix)
import qualified Data.Map.Strict as M
import qualified Data.Map.Lazy as Lazy
import qualified Data.Set as S

-- | The references a traversal may rename. Values are free variables only.
data Names m = Names
  { onType :: String -> m String, onConstructor :: String -> m String
  , onRefinement :: String -> m String, onValue :: String -> m String
  , onLaw :: String -> m String }

data Kind = TypeName | ConstructorName | RefinementName | ValueName | LawName
  deriving (Eq, Ord, Show)

-- | An imported definition's name in the importing unit, e.g. shop.money's add
-- is shopMoneyAdd. Checked definitions are emitted as target code, so the name
-- must be an identifier in every target.
importedDefinitionName :: String -> String -> String
importedDefinitionName unit name = case segments unit of
  first : rest -> first ++ concatMap capital rest ++ capital name
  [] -> name
  where capital (c : cs) = toUpper c : cs
        capital [] = []

stripSuffix :: String -> String -> Maybe String
stripSuffix suffix s
  | suffix `isSuffixOf` s = Just (take (length s - length suffix) s)
  | otherwise = Nothing

segments :: String -> [String]
segments s = case break (== '.') s of
  (a, _ : rest) -> a : segments rest
  (a, []) -> [a]

importedRefinementName :: String -> String -> String
importedRefinementName unit name = unit ++ "::" ++ name

importedLawName :: String -> String -> String
importedLawName unit name = name ++ " (" ++ unit ++ ")"

qualifiedTypeName :: String -> String -> String
qualifiedTypeName unit name = unit ++ "::type::" ++ name

-- | What a unit declares itself, with the names other units refer to it by.
data Exports = Exports
  { exportTypes :: M.Map String String
  , exportConstructors :: M.Map String String
  , exportOwners :: M.Map String [String]
  , exportRefinements :: M.Map String String
  , exportDefinitions :: M.Map String String
  , exportLaws :: M.Map String String
  , exportConcreteLaws :: [String]
  , exportAdapters :: [String]
  , exportIndices :: M.Map String [String]
  -- Abilities by name, and their operations by name: an importer reaches
  -- them as alias.Ability and alias.op.
  , exportAbilities :: M.Map String String
  , exportOperations :: M.Map String String }

data Resolved = Resolved { resolvedUnit :: Unit, resolvedExports :: Exports, portable :: Unit }

-- | visible importer imported: Nothing when the import is allowed, or the reason
-- it is not (package boundaries).
resolveImports :: (String -> String -> Maybe String) -> [(Unit, [Import])] -> Either [Diagnostic] [Unit]
resolveImports visible units = mapM (\(u, _) -> resolvedUnit <$> table Lazy.! unitName u) units
  where
    -- Lazy in import order; LawSpec.Parser rejects import cycles.
    table = Lazy.fromList [(unitName u, resolveUnit visible table u imports) | (u, imports) <- units]

resolveUnit :: (String -> String -> Maybe String) -> M.Map String (Either [Diagnostic] Resolved)
  -> Unit -> [Import] -> Either [Diagnostic] Resolved
resolveUnit visible table u allImports = do
  let imports = [i | i <- allImports, not (null (importUnit i))]
      exportLines = [i | i <- allImports, null (importUnit i)]
      at i = Just (spanStart (importSpan i))
      failAt i message = Left [Diagnostic "import" message (at i)]
  sources <- forM imports $ \i -> do
    when (importUnit i == "prelude") (failAt i "prelude is available without an import")
    when (importAlias i == "prelude") (failAt i "prelude is reserved and cannot be an import alias")
    maybe (pure ()) (failAt i) (visible (unitName u) (importUnit i))
    source <- maybe (failAt i ("unknown unit: " ++ importUnit i)) id (Lazy.lookup (importUnit i) table)
    pure (i, source)
  let aliases = map importAlias imports
  forM_ imports $ \i -> when (length (filter (== importAlias i) aliases) > 1)
    (failAt i ("duplicate import alias: " ++ importAlias i))
  -- A built-in unit's implicit import (from "<unit>") may sit beside an
  -- explicit import of it, under its own alias.
  let explicit i = case importSpan i of Span (Location file _ _) _ -> take 1 file /= "<"
  forM_ (filter explicit imports) $ \i -> when (length (filter ((== importUnit i) . importUnit) (filter explicit imports)) > 1)
    (failAt i ("unit imported more than once: " ++ importUnit i))
  scopes <- forM sources $ \(i, source) -> importScope u i (resolvedExports source)
  let scope = M.unionsWith (++) [M.map pure s | s <- scopes]
  forM_ (M.toList scope) $ \((_, name), targets) ->
    when (length (nub targets) > 1) $ Left [Diagnostic "import"
      (name ++ " is imported from more than one unit; use a qualified name") Nothing]
  let aliasUnits = M.fromList [(importAlias i, (importUnit i, resolvedExports source)) | (i, source) <- sources]
      lookupName kind name = case M.lookup (kind, name) scope of
        Just (target : _) -> Right target
        _ -> case break (== '.') name of
          (alias, '.' : rest) | Just (unit, exports) <- M.lookup alias aliasUnits
                              , kind /= LawName || take 1 rest == "`" ->
            Left [Diagnostic "import" (missing unit exports kind rest) Nothing]
          _ -> Right name
      names = Names (lookupName TypeName) (lookupName ConstructorName)
        (lookupName RefinementName) (lookupName ValueName) (lookupName LawName)
  renamed <- walkUnit names u
  -- Copy what the renamed unit uses, and what that uses in turn.
  let origins = [(resolvedUnit source, portable source) | (_, source) <- sources]
      -- Arithmetic on durations elaborates to the time unit's definitions
      -- once types are known, so a unit importing it copies them all.
      timeSeeds = S.fromList [(ValueName, n) | i <- imports, importUnit i == timeUnit, d <- durationDefinitions ++ instantDefinitions,
        Right n <- [lookupName ValueName (importAlias i ++ "." ++ d)]] `S.union`
        -- The workflow runtime drives the resilience unit's state machines.
        S.fromList [(ValueName, n) | i <- imports, importUnit i == resilienceUnit, d <- resilienceDefinitions,
          Right n <- [lookupName ValueName (importAlias i ++ "." ++ d)]]
  -- Re-exports: each listed name resolves to what this unit imports it as.
  reexports <- forM [(i, item) | i <- exportLines, item <- importItems i] $ \(i, item) -> do
    let law = "`" `isSuffixOf` item
        base = if law then item else reverse (takeWhile (/= '.') (reverse item))
        resolvedAs kind = case M.lookup (kind, if kind == LawName then unquote item else item) scope of
          Just (target : _) -> [(kind, base, target)]
          _ -> []
        found = if law then resolvedAs LawName
          else concatMap resolvedAs [TypeName, ConstructorName, RefinementName, ValueName] ++
            [(RefinementName, base ++ "@index", t) | Just (t : _) <- [M.lookup (RefinementName, item ++ "@index") scope]]
    when (null found) (failAt i ("export names " ++ unquote item ++ ", which " ++ unitName u ++ " does not import"))
    pure found
  let reexported = concat reexports
      reexportNames = nub [n | (_, n, _) <- reexported]
  forM_ reexportNames $ \n -> when (length (nub [t | (k, m, t) <- reexported, m == n, k /= ConstructorName]) > 1)
    (Left [Diagnostic "import" ("export lists " ++ unquote n ++ " twice, from different units") Nothing])
  let localNames = map dataTypeName (dataTypes u) ++ [dataConstructorName c | d <- dataTypes u, c <- dataTypeConstructors d] ++
        map refinementName (refinements u) ++ map fst (functions u) ++ map lawName (laws u)
  forM_ reexportNames $ \n -> when (unquote n `elem` localNames)
    (Left [Diagnostic "import" ("export lists " ++ unquote n ++ ", which " ++ unitName u ++ " also declares") Nothing])
      -- What a facade re-exports is copied into it, so its importers find it.
  let reexportSeeds = S.fromList [(k, t) | (k, _, t) <- reexported, k `elem` [RefinementName, ValueName, LawName]]
      -- Every ability and handler of an imported unit comes along, as a copy
      -- that remembers the unit declaring it (and so do the definitions its
      -- handlers use). A unit's own declarations win no clash: a name both
      -- declared and imported is an error.
      fromUnit source get origin = [(if null (origin x) then unitName (resolvedUnit source) else origin x, x) | x <- get (portable source)]
      copiedAbilities = nubOn (\(o, a) -> (o, abilityName a))
        (concat [fromUnit source abilities abilityOrigin | (_, source) <- sources])
      copiedHandlers = nubOn (\(o, h) -> (o, handlerName h))
        (concat [fromUnit source handlerDeclarations handlerOrigin | (_, source) <- sources])
      copySeeds = S.unions ([collect (walkAbility collector a) | (_, a) <- copiedAbilities] ++
        [collect (walkHandler collector h) | (_, h) <- copiedHandlers])
      wanted = unitReferences renamed `S.union` timeSeeds `S.union` reexportSeeds `S.union` copySeeds
  copies <- closure origins wanted
  let (refinements', definitions', laws') = copies
      natural = [r | r <- refinements', refinementName r == naturalRefinementName]
      copiedRefinements = [r | r <- refinements', refinementName r /= naturalRefinementName]
      needsNatural = not (null natural) && naturalRefinementName `notElem` map refinementName (refinements renamed)
      signatures = M.toList (M.fromList [(n, t) | (_, p) <- origins, (n, t) <- functions p, n `elem` map functionName definitions'])
      clashes = [functionName d | d <- definitions', functionName d `elem` map fst (functions renamed)] ++
        [lawName l | l <- laws', lawName l `elem` map lawName (laws renamed)]
  unless (null clashes) $ Left [Diagnostic "import"
    ("imported names clash with declarations of " ++ unitName u ++ ": " ++ intercalate ", " clashes) Nothing]
  let abilityClashes = [abilityName a | (_, a) <- copiedAbilities, abilityName a `elem` map abilityName (abilities renamed)] ++
        [handlerName h | (_, h) <- copiedHandlers, handlerName h `elem` map handlerName (handlerDeclarations renamed)] ++
        [abilityName a | (o, a) <- copiedAbilities, (o', b) <- copiedAbilities, abilityName a == abilityName b, o /= o'] ++
        [handlerName h | (o, h) <- copiedHandlers, (o', g) <- copiedHandlers, handlerName h == handlerName g, o /= o']
  unless (null abilityClashes) $ Left [Diagnostic "import"
    ("abilities or handlers of the same name come from two places in " ++ unitName u ++ ": " ++ intercalate ", " (nub abilityClashes)) Nothing]
  let resolved = renamed
        { refinements = take 1 natural `onlyIf` needsNatural ++ refinements renamed ++ copiedRefinements
        , functionDefinitions = functionDefinitions renamed ++ definitions'
        , functions = functions renamed ++ signatures
        , laws = laws renamed ++ laws'
        , abilities = abilities renamed ++ [a { abilityOrigin = o } | (o, a) <- copiedAbilities]
        , handlerDeclarations = handlerDeclarations renamed ++ [h { handlerOrigin = o } | (o, h) <- copiedHandlers]
        , declarationSpans = declarationSpans renamed ++
            [(functionName d, functionSpan d) | d <- definitions'] }
      copiedNames = S.fromList (map refinementName copiedRefinements ++ map functionName definitions' ++ map lawName laws')
      own = unitExports copiedNames resolved
      -- A re-exported type keeps its constructors, from the unit that declares it.
      ownersOf target = concat [M.findWithDefault [] n (exportOwners (resolvedExports source)) |
        (_, source) <- sources, (n, q) <- M.toList (exportTypes (resolvedExports source)), q == target]
      exports = own
        { exportTypes = M.union (exportTypes own) (M.fromList [(n, t) | (TypeName, n, t) <- reexported])
        , exportConstructors = M.union (exportConstructors own) (M.fromList ([(n, t) | (ConstructorName, n, t) <- reexported] ++
            [(c, q) | (TypeName, _, t) <- reexported, (_, source) <- sources,
              (c, q) <- M.toList (exportConstructors (resolvedExports source)), (t ++ "::") `isPrefixOf'` q]))
        , exportOwners = M.union (exportOwners own) (M.fromList [(n, ownersOf t) | (TypeName, n, t) <- reexported])
        , exportRefinements = M.union (exportRefinements own) (M.fromList [(n, t) | (RefinementName, n, t) <- reexported])
        , exportDefinitions = M.union (exportDefinitions own) (M.fromList [(n, t) | (ValueName, n, t) <- reexported])
        , exportLaws = M.union (exportLaws own) (M.fromList [(unquote n, t) | (LawName, n, t) <- reexported]) }
  pure (Resolved resolved exports (portableUnit exports resolved))
  where
    isPrefixOf' prefix s = take (length prefix) s == prefix
    nubOn key = foldr (\x acc -> if key x `elem` map key acc then acc else x : acc) []
    unquote n = filter (/= '`') n
    xs `onlyIf` condition = if condition then xs else []
    missing unit exports kind name
      | name `elem` exportAdapters exports =
          name ++ " is an adapter of " ++ unit ++ "; adapters belong to their unit, so import its laws or definitions"
      | kind == LawName, unquote name `elem` exportConcreteLaws exports =
          "law " ++ unquote name ++ " of " ++ unit ++ " has no parameters; only generic laws can be imported"
      | otherwise = unit ++ " does not export " ++ unquote name

-- | The unqualified and alias-qualified names one import brings into scope.
importScope :: Unit -> Import -> Exports -> Either [Diagnostic] (M.Map (Kind, String) String)
importScope u i exports = do
  let alias = importAlias i
      failAt message = Left [Diagnostic "import" message (Just (spanStart (importSpan i)))]
      qualified = M.fromList $
        [((TypeName, alias ++ "." ++ n), q) | (n, q) <- M.toList (exportTypes exports)] ++
        [((ConstructorName, alias ++ "." ++ n), q) | (n, q) <- M.toList (exportConstructors exports)] ++
        [((RefinementName, alias ++ "." ++ n), q) | (n, q) <- M.toList (exportRefinements exports)] ++
        [((ValueName, alias ++ "." ++ n), q) | (n, q) <- M.toList (exportDefinitions exports)] ++
        [((LawName, alias ++ ".`" ++ n ++ "`"), q) | (n, q) <- M.toList (exportLaws exports)] ++
        -- An imported ability keeps its name, and so do its operations.
        [((TypeName, alias ++ "." ++ n), q) | (n, q) <- M.toList (exportAbilities exports)] ++
        [((ValueName, alias ++ "." ++ n), q) | (n, q) <- M.toList (exportOperations exports)]
      local = S.fromList $ map dataTypeName (dataTypes u) ++
        [dataConstructorName c | d <- dataTypes u, c <- dataTypeConstructors d] ++
        map refinementName (refinements u) ++ map fst (functions u) ++ map lawName (laws u)
  -- The implicit collections import leaves out what the unit declares, and
  -- the containers' constructors, which keep their items canonical.
  let implicit = importUnit i `elem` [collectionsUnit, timeUnit, resilienceUnit, matchersUnit, resourcesUnit]
      hidden = [c | Just c <- map internalConstructor (importItems i)]
  listed <- forM [item | item <- importItems i, not (implicit && unquote item `S.member` local)] $ \item -> do
    when (unquote item `S.member` local)
      (failAt (unquote item ++ " is imported from " ++ importUnit i ++ " and also declared in " ++ unitName u))
    let law = "`" `isSuffixOf` item
        n = unquote item
        found = if law
          then [((LawName, n), q) | Just q <- [M.lookup n (exportLaws exports)]]
          else [((TypeName, n), q) | Just q <- [M.lookup n (exportTypes exports)]] ++
            [((ConstructorName, c), q) | Just cs <- [M.lookup n (exportOwners exports)], c <- cs,
              Just q <- [M.lookup c (exportConstructors exports)]] ++
            [((RefinementName, r), q) | (r, q) <- M.toList (exportRefinements exports), r == n || r == n ++ "@index"] ++
            [((ValueName, n), q) | Just q <- [M.lookup n (exportDefinitions exports)]] ++
            [((TypeName, n), q) | Just q <- [M.lookup n (exportAbilities exports)]] ++
            -- A listed type brings the functions generated for it: a
            -- wrapper's valueOf<Name> and an indexed family's measures.
            [((ValueName, d), q) | M.member n (exportTypes exports), (d, q) <- M.toList (exportDefinitions exports),
              d `elem` ("valueOf" ++ n) : [index ++ "Of" ++ n | index <- M.findWithDefault [] n (exportIndices exports)]]
    when (null found) $ failAt $ if not law && M.member n (exportConstructors exports)
      then n ++ " is a constructor; import its type to use it unqualified"
      else if law && n `elem` exportConcreteLaws exports
        then "law " ++ n ++ " of " ++ importUnit i ++ " has no parameters; only generic laws can be imported"
        else if n `elem` exportAdapters exports
          then n ++ " is an adapter of " ++ importUnit i ++ "; adapters belong to their unit"
          else importUnit i ++ " does not export " ++ n
    pure found
  let items = [entry | entry@((kind, n), _) <- concat listed, not (implicit && kind == ConstructorName && (n `elem` hidden || n `S.member` local))]
  forM_ (nub (map (snd . fst) items)) $ \n ->
    when (n `elem` [dataConstructorName c | d <- dataTypes u, c <- dataTypeConstructors d])
      (failAt (n ++ " is imported from " ++ importUnit i ++ " and also declared in " ++ unitName u))
  pure (M.union qualified (M.fromList items))
  where unquote = filter (/= '`')

-- | A unit's own declarations: not the copies its imports brought in.
unitExports :: S.Set String -> Unit -> Exports
unitExports copied u = Exports
  { exportTypes = M.fromList [(dataTypeName d, qualifiedTypeName (unitName u) (dataTypeName d)) | d <- dataTypes u]
  , exportConstructors = M.fromList
      [ (dataConstructorName c, qualifiedTypeName (unitName u) (dataTypeName d) ++ "::" ++ dataConstructorName c)
      | d <- dataTypes u, c <- dataTypeConstructors d ]
  , exportOwners = M.fromList [(dataTypeName d, map dataConstructorName (dataTypeConstructors d)) | d <- dataTypes u]
  , exportRefinements = M.fromList
      [ (refinementName r, if refinementName r == naturalRefinementName then naturalRefinementName
          else importedRefinementName (unitName u) (refinementName r))
      | r <- refinements u, not (refinementName r `S.member` copied) ]
  , exportDefinitions = M.fromList
      [ (functionName d, importedDefinitionName (unitName u) (functionName d))
      | d <- functionDefinitions u, not (functionName d `S.member` copied) ]
  , exportLaws = M.fromList
      [ (lawName l, importedLawName (unitName u) (lawName l))
      | l <- laws u, not (null (parameters l)), not (lawName l `S.member` copied) ]
  , exportConcreteLaws = [lawName l | l <- laws u, null (parameters l)]
  , exportAdapters = [n | (n, _) <- functions u, n `notElem` map functionName (functionDefinitions u), n `notElem` operationNames u]
  , exportAbilities = M.fromList [(abilityName a, abilityName a) | a <- abilities u]
  , exportOperations = M.fromList [(op, op) | a <- abilities u, (op, _) <- abilityOperations a]
  , exportIndices = M.fromList
      [ (family, [p | (p, RefinementApp r []) <- refinementParameters refinement, r == naturalRefinementName])
      | refinement <- refinements u, Just family <- [stripSuffix "@index" (refinementName refinement)] ] }

-- | The unit with its own names replaced by the names every importer uses, so
-- its declarations can be copied as they are.
portableUnit :: Exports -> Unit -> Unit
portableUnit exports u = runIdentity $ do
  let rename table n = Identity (M.findWithDefault n n table)
      names = Names (rename (exportTypes exports)) (rename (exportConstructors exports))
        (rename (exportRefinements exports)) (rename (exportDefinitions exports)) (rename (exportLaws exports))
      declared table n = M.findWithDefault n n table
  walked <- walkUnit names u
  pure walked
    { refinements = [r{refinementName = declared (exportRefinements exports) (refinementName r)} | r <- refinements walked]
    , functionDefinitions = [d{functionName = declared (exportDefinitions exports) (functionName d)} | d <- functionDefinitions walked]
    , functions = [(declared (exportDefinitions exports) n, t) | (n, t) <- functions walked]
    , laws = [l{lawName = declared (exportLaws exports) (lawName l)} | l <- laws walked] }

-- | Everything the given references need from the imported units. A copied
-- declaration may not use its unit's adapters or concrete laws.
closure :: [(Unit, Unit)] -> S.Set (Kind, String) -> Either [Diagnostic] ([Refinement], [FunctionDefinition], [Law])
closure origins seed = go S.empty ([], [], []) (S.filter imported seed)
  where
    refinementTable = M.fromList [(refinementName r, r) | (_, p) <- origins, r <- refinements p]
    definitionTable = M.fromList [(functionName d, d) | (_, p) <- origins, d <- functionDefinitions p]
    lawTable = M.fromList [(lawName l, l) | (_, p) <- origins, l <- laws p, not (null (parameters l))]
    adapters = M.fromList [(n, unitName o) | (o, p) <- origins, (n, _) <- functions p, n `notElem` map functionName (functionDefinitions p), n `notElem` operationNames p]
    concrete = M.fromList [(lawName l, unitName o) | (o, p) <- origins, l <- laws p, null (parameters l)]
    imported (kind, n) = case kind of
      RefinementName -> M.member n refinementTable
      ValueName -> M.member n definitionTable
      LawName -> M.member n lawTable
      _ -> False
    uses refs = do
      forM_ (S.toList refs) $ \reference -> case reference of
        (ValueName, n) | not (imported reference), Just unit <- M.lookup n adapters ->
          Left [Diagnostic "import" (n ++ " is an adapter of " ++ unit ++ "; an imported law or definition cannot use it") Nothing]
        (LawName, n) | not (imported reference), Just unit <- M.lookup n concrete ->
          Left [Diagnostic "import" ("an imported law invokes " ++ n ++ " of " ++ unit ++ ", which has no parameters") Nothing]
        _ -> pure ()
      pure (S.filter imported refs)
    go seen (rs, ds, ls) pending = case S.minView (S.difference pending seen) of
      Nothing -> Right (reverse rs, reverse ds, reverse ls)
      Just (reference@(kind, n), rest) -> do
        let seen' = S.insert reference seen
        case kind of
          RefinementName | Just r <- M.lookup n refinementTable -> do
            more <- uses (refinementReferences r)
            go seen' (r : rs, ds, ls) (S.union rest more)
          ValueName | Just d <- M.lookup n definitionTable -> do
            more <- uses (definitionReferences d)
            go seen' (rs, d : ds, ls) (S.union rest more)
          LawName | Just l <- M.lookup n lawTable -> do
            more <- uses (lawReferences l)
            go seen' (rs, ds, l : ls) (S.union rest more)
          _ -> go seen' (rs, ds, ls) rest

unitReferences :: Unit -> S.Set (Kind, String)
unitReferences u = collect (walkUnit (collector) u)

refinementReferences :: Refinement -> S.Set (Kind, String)
refinementReferences r = collect (walkRefinement collector r)

definitionReferences :: FunctionDefinition -> S.Set (Kind, String)
definitionReferences d = collect (walkFunctionDefinition collector d)

lawReferences :: Law -> S.Set (Kind, String)
lawReferences l = collect (walkLaw collector l)

collector :: Names (State (S.Set (Kind, String)))
collector = Names (record TypeName) (record ConstructorName) (record RefinementName) (record ValueName) (record LawName)
  where
    record :: Kind -> String -> State (S.Set (Kind, String)) String
    record kind n = modify (S.insert (kind, n)) >> pure n

collect :: State (S.Set (Kind, String)) a -> S.Set (Kind, String)
collect action = execState action S.empty

-- | Traversals. Binders shadow: only free variables are value references.
walkUnit :: Monad m => Names m -> Unit -> m Unit
walkUnit names u = do
  functions' <- forM (functions u) $ \(n, t) -> (,) n <$> walkType names [] t
  laws' <- mapM (walkLaw names) (laws u)
  refinements' <- mapM (walkRefinement names) (refinements u)
  dataTypes' <- forM (dataTypes u) $ \d -> do
    constructors <- forM (dataTypeConstructors d) $ \c -> do
      let scope = map fst (dataConstructorFields c)
      fields <- forM (dataConstructorFields c) $ \(n, t) -> (,) n <$> walkType names scope t
      pure c{dataConstructorFields = fields}
    pure d{dataTypeConstructors = constructors}
  definitions' <- mapM (walkFunctionDefinition names) (functionDefinitions u)
  abilities' <- mapM (walkAbility names) (abilities u)
  handlers' <- mapM (walkHandler names) (handlerDeclarations u)
  uses' <- forM (declaredUses u) $ \(n, ts) -> (,) n <$> mapM (walkType names []) ts
  resources' <- forM (resourceDeclarations u) $ \r -> do
    ty <- walkType names [] (resourceType r)
    acquire <- walkExpr names [] (resourceAcquire r)
    let clause (n, body) = (,) n <$> walkExpr names [n] body
    release <- clause (resourceRelease r)
    reset <- traverse clause (resourceReset r)
    pure r{resourceType = ty, resourceAcquire = acquire, resourceRelease = release, resourceReset = reset}
  harness' <- traverse (walkHarness names (concatMap lawInputNames (laws u))) (unitHarness u)
  pure u{functions = functions', laws = laws', refinements = refinements', dataTypes = dataTypes', functionDefinitions = definitions', resourceDeclarations = resources'
        , abilities = abilities', handlerDeclarations = handlers', declaredUses = uses', unitHarness = harness'}

-- A harness's strategies and expressions name the unit's imports like its
-- laws do; an expression's free names other than imports are law inputs.
walkHarness :: Monad m => Names m -> [String] -> HarnessDeclaration -> m HarnessDeclaration
walkHarness names inputs h = do
  items <- forM (harnessItems h) $ \item -> case item of
    HarnessStrategy sd -> do
      ty <- walkType names [] (strategyType sd)
      body <- gen [] (strategyBody sd)
      pure (HarnessStrategy sd{strategyType = ty, strategyBody = body})
    HarnessDefault setting range -> (`HarnessDefault` range) <$> setting' setting
    HarnessFor laws' settings range -> (\ss -> HarnessFor laws' ss range) <$> forM settings (\(st, r) -> (\st' -> (st', r)) <$> setting' st)
    HarnessBenchmark n e range -> (\e' -> HarnessBenchmark n e' range) <$> walkExpr names [] e
    other -> pure other
  pure h{harnessItems = items}
  where
    gen scope g = case g of
      GenAny t -> GenAny <$> traverse (walkType names []) t
      GenNamed n -> pure (GenNamed n)
      GenOneOf es -> GenOneOf <$> mapM (walkExpr names scope) es
      GenFrequency alternatives -> GenFrequency <$> forM alternatives (\(w, a) -> (,) w <$> gen scope a)
      GenSuchThat inner p n -> (\i p' -> GenSuchThat i p' n) <$> gen scope inner <*> walkExpr names ("it" : scope) p
      GenBind x t from body -> GenBind x <$> walkType names [] t <*> gen scope from <*> gen (x : scope) body
    setting' st = case st of
      CoverSetting p l e -> CoverSetting p l <$> walkExpr names inputs e
      ClassifySetting e l -> (`ClassifySetting` l) <$> walkExpr names inputs e
      LabelSetting e -> LabelSetting <$> walkExpr names inputs e
      TargetMaximize e -> TargetMaximize <$> walkExpr names inputs e
      other -> pure other

-- A law's inputs, by name.
lawInputNames :: Law -> [String]
lawInputNames l = map fst (parameters l) ++ forallNames (definition l)
  where
    forallNames d = case d of
      Forall bound body -> map fst bound ++ forallNames body
      Implies _ body -> forallNames body
      And a b -> forallNames a ++ forallNames b
      _ -> []

walkAbility :: Monad m => Names m -> AbilityDeclaration -> m AbilityDeclaration
walkAbility names a = do
  operations <- forM (abilityOperations a) $ \(n, t) -> (,) n <$> walkType names [] t
  abilityLaws' <- mapM (walkLaw names) (abilityLaws a)
  pure a{abilityOperations = operations, abilityLaws = abilityLaws'}

walkHandler :: Monad m => Names m -> HandlerDeclaration -> m HandlerDeclaration
walkHandler names h = do
  ability <- walkType names [] (handlerAbility h)
  state <- forM (handlerState h) $ \(s, t, e) -> (,,) s <$> walkType names [] t <*> walkExpr names [] e
  let stateNames = maybe [] (\(s, _, _) -> [s]) (handlerState h)
  clauses <- forM (handlerClauses h) $ \c -> do
    body <- walkExpr names (clauseParameters c ++ stateNames) (clauseBody c)
    pure c{clauseBody = body}
  pure h{handlerAbility = ability, handlerState = state, handlerClauses = clauses}

walkRefinement :: Monad m => Names m -> Refinement -> m Refinement
walkRefinement names r = do
  parameters' <- forM (refinementParameters r) $ \(n, t) -> (,) n <$> walkType names [] t
  let scope = [n | (n, t) <- refinementParameters r, t /= Named "Type"]
  requirements' <- mapM (walkConstraint names) (refinementRequirements r)
  body <- walkType names scope (refinementBody r)
  pure r{refinementParameters = parameters', refinementRequirements = requirements', refinementBody = body}

walkFunctionDefinition :: Monad m => Names m -> FunctionDefinition -> m FunctionDefinition
walkFunctionDefinition names d = do
  let scope = map fst (functionArguments d)
  arguments <- forM (functionArguments d) $ \(n, t) -> (,) n <$> walkType names scope t
  result <- walkType names scope (functionResult d)
  requirements' <- mapM (walkConstraint names) (functionRequirements d)
  body <- walkExpr names scope (functionBody d)
  pure d{functionArguments = arguments, functionResult = result, functionRequirements = requirements', functionBody = body}

walkLaw :: Monad m => Names m -> Law -> m Law
walkLaw names l = do
  let scope = map fst (parameters l) ++ map fst (lawResources l)
      bound = scope ++ quantified (definition l)
  parameters' <- forM (parameters l) $ \(n, t) -> (,) n <$> walkType names scope t
  resources' <- forM (lawResources l) $ \(n, t) -> (,) n <$> walkType names [] t
  requirements' <- mapM (walkConstraint names) (requirements l)
  body <- walkDefinition names scope (definition l)
  examples' <- forM (examples l) $ \e -> do
    bindings' <- forM (bindings e) $ \(n, v) -> (,) n <$> walkLiteral names v
    checks <- forM (expectations e) $ \x ->
      Expectation <$> walkExpr names bound (actual x) <*> walkLiteral names (expected x)
    pure e{bindings = bindings', expectations = checks}
  pure l{parameters = parameters', requirements = requirements', definition = body, examples = examples', lawResources = resources'}
  where
    quantified (Forall qs d) = map fst qs ++ quantified d
    quantified (Implies _ d) = quantified d
    quantified (And a b) = quantified a ++ quantified b
    quantified _ = []

walkDefinition :: Monad m => Names m -> [String] -> Definition -> m Definition
walkDefinition names scope d = case d of
  Forall qs body -> do
    let scope' = scope ++ map fst qs
    qs' <- forM qs $ \(n, t) -> (,) n <$> walkType names scope' t
    Forall qs' <$> walkDefinition names scope' body
  Equal a b -> Equal <$> walkExpr names scope a <*> walkExpr names scope b
  Holds a -> Holds <$> walkExpr names scope a
  Implies g body -> Implies <$> walkExpr names scope g <*> walkDefinition names scope body
  And a b -> And <$> walkDefinition names scope a <*> walkDefinition names scope b
  Invoke n args -> Invoke <$> onLaw names n <*> mapM (walkExpr names scope) args

walkConstraint :: Monad m => Names m -> Constraint -> m Constraint
walkConstraint names (Capability c t) = Capability c <$> walkType names [] t

walkLiteral :: Monad m => Names m -> Literal -> m Literal
walkLiteral names v = case v of
  ConstructorLiteral n fields -> ConstructorLiteral <$> onConstructor names n <*> mapM (walkLiteral names) fields
  ListLiteral xs -> ListLiteral <$> mapM (walkLiteral names) xs
  other -> pure other

walkType :: Monad m => Names m -> [String] -> Type -> m Type
walkType names scope t = case t of
  Named n -> Named <$> onType names n
  Variable n -> pure (Variable n)
  Arrow a b -> Arrow <$> walkType names scope a <*> walkType names scope b
  Applied n a -> Applied <$> onType names n <*> walkType names scope a
  Application n args -> Application <$> onType names n <*> mapM (walkType names scope) args
  Refined n a p -> Refined n <$> walkType names scope a <*> traverse (walkExpr names (n : scope)) p
  RefinementApp n args -> RefinementApp <$> onRefinement names n <*> forM args (\argument -> case argument of
    TypeArgument a -> TypeArgument <$> walkType names scope a
    ValueArgument e -> ValueArgument <$> walkExpr names scope e)
  Qualified cs a -> Qualified <$> mapM (walkConstraint names) cs <*> walkType names scope a
  CheckedType es a -> CheckedType <$> mapM (walkExpr names scope) es <*> walkType names scope a

walkExpr :: Monad m => Names m -> [String] -> Expr -> m Expr
walkExpr names scope e = case e of
  Located range inner -> Located range <$> walkExpr names scope inner
  -- prelude.<op> of a collection is a definition of the collections unit.
  Var n | n `notElem` scope, Just op <- stripPrefix "prelude." n, Just (definition, _) <- collectionOperation op ->
          Var <$> onValue names (collectionsAlias ++ "." ++ definition)
  -- prelude.<op> of a matcher over lists is a definition of the matchers unit.
  Var n | n `notElem` scope, Just op <- stripPrefix "prelude." n, Just definition <- matcherOperation op ->
          Var <$> onValue names (matchersAlias ++ "." ++ definition)
  -- prelude.<op> of a duration is a definition of the time unit.
  Var n | n `notElem` scope, Just op <- stripPrefix "prelude." n, Just definition <- timeOperation op ->
          Var <$> onValue names (timeAlias ++ "." ++ definition)
  Var n | n `elem` scope || take 8 n == "prelude." -> pure (Var n)
        | otherwise -> Var <$> onValue names n
  Apply a b -> Apply <$> walkExpr names scope a <*> walkExpr names scope b
  Compose a b -> Compose <$> walkExpr names scope a <*> walkExpr names scope b
  ListLit xs -> ListLit <$> mapM (walkExpr names scope) xs
  ConstructLit n fields -> ConstructLit <$> onConstructor names n <*> mapM (walkExpr names scope) fields
  MatchExpr value branches -> MatchExpr <$> walkExpr names scope value <*> forM branches (\(MatchBranch tag binders body) ->
    -- A matcher's wildcard branch _ names no constructor.
    MatchBranch <$> (if tag == "_" then pure tag else onConstructor names tag) <*> pure binders <*> walkExpr names (binders ++ scope) body)
  AllElementsExpr value binder predicate ->
    AllElementsExpr <$> walkExpr names scope value <*> pure binder <*> walkExpr names (binder : scope) predicate
  AllPayloadsExpr value predicates -> AllPayloadsExpr <$> walkExpr names scope value <*>
    forM predicates (\(binder, body) -> (,) binder <$> walkExpr names (binder : scope) body)
  Binary op a b -> Binary op <$> walkExpr names scope a <*> walkExpr names scope b
  Unary op a -> Unary op <$> walkExpr names scope a
  Annotate a ty -> Annotate <$> walkExpr names scope a <*> walkType names scope ty
  TypeBound bound ty -> TypeBound bound <$> walkType names scope ty
  other -> pure other
