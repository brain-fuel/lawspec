-- Harness units: the implementation plane of a unit (see
-- docs/reference/language/harness.md and docs/explanation/abilities.md).
--
-- A law says what must hold for every lawful handler and every input. A
-- harness chooses how that is tested: which lawful handlers the tests run
-- against, how inputs are drawn, how adequate the evidence must be, and the
-- run's metadata (tags, skips, timeouts, retries, order, sharing,
-- benchmarks). It can never change what a law means, and this pass enforces
-- that:
--
--   * a harness serves one unit and refers only to that unit's laws,
--     handlers and resources (the parser already rejects any law,
--     definition, ability, handler, type or signature declared in one);
--   * `test with` only narrows the lawful handlers a law runs against, and
--     never a handler the law names with `using`: that one is part of the
--     claim. A law variant the harness leaves out is still an obligation,
--     reported as skipped;
--   * a strategy produces values of the type it declares (LawSpec.Frontend
--     type-checks it against each input it is used for), and every value it
--     draws is still checked against the input's refinements when the tests
--     run;
--   * a resource is shared only when it declares `reset`, since otherwise
--     one law would observe what another left behind.
--
-- The result is one HarnessPlan per law, by the law's final name (after
-- LawSpec.Abilities names its handler variants), with strategies inlined.
-- Its expressions are elaborated, and checked to call only checked
-- definitions, by LawSpec.Frontend.
module LawSpec.Harness
  ( elaborateHarness, emptyPlan, lawBaseMatches, genReferences
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.List (intercalate, isInfixOf, isPrefixOf, nub)
import qualified Data.Map.Strict as M
import LawSpec.Model

type Failure = (Maybe Location, String)

emptyPlan :: String -> HarnessPlan
emptyPlan name = HarnessPlan name [] Nothing Nothing Nothing 1 0 [] [] [] Nothing [] Nothing

-- Whether a law's final name is the law written as base: the law itself, one
-- of its handler variants (`base [native]`), or, for an ability's law, one
-- of its per-handler copies (`Gateway: base [fakeGateway]`).
lawBaseMatches :: [String] -> String -> String -> Bool
lawBaseMatches abilityNames base final =
  final == base || (base ++ " [") `isPrefixOf` final ||
  (any (`isPrefixOf` final) abilityNames && (": " ++ base ++ " [") `isInfixOf` final)

-- The strategies a strategy body names.
genReferences :: Gen -> [String]
genReferences g = case g of
  GenAny _ -> []
  GenNamed n -> [n]
  GenOneOf _ -> []
  GenFrequency alternatives -> concatMap (genReferences . snd) alternatives
  GenSuchThat inner _ _ -> genReferences inner
  GenBind _ _ from body -> genReferences from ++ genReferences body

elaborateHarness :: Unit -> Either Failure Unit
elaborateHarness u = case unitHarness u of
  Nothing -> pure u
  Just h -> do
    let at s = Just (spanStart s)
        items = harnessItems h
        strategies = [s | HarnessStrategy s <- items]
        strategyTable = M.fromList [(strategyName s, s) | s <- strategies]
        handlerNames = map handlerName (handlerDeclarations u)
        abilityNames = map abilityName (abilities u)
        finalNames = map lawName (laws u)
        unitLabel = unitName u
    unless (harnessFor h == unitName u)
      (Left (at (harnessSpan h), "the harness " ++ harnessName h ++ " is for " ++ harnessFor h ++
        ", but it is written with the unit " ++ unitName u))
    -- Strategies: unique, naming only strategies of this harness, without cycles.
    forM_ strategies $ \s -> do
      when (length (filter ((== strategyName s) . strategyName) strategies) > 1)
        (Left (at (strategySpan s), "the strategy " ++ strategyName s ++ " is declared twice"))
      forM_ (genReferences (strategyBody s)) $ \n -> unless (M.member n strategyTable)
        (Left (at (strategySpan s), "the strategy " ++ strategyName s ++ " uses " ++ n ++
          ", but this harness has no strategy called " ++ n ++ " (write `any` for the default generator)"))
      checkGen (at (strategySpan s)) (strategyBody s)
    let cyclic seen n = case M.lookup n strategyTable of
          Nothing -> False
          Just s -> any (\r -> r `elem` seen || cyclic (r : seen) r) (genReferences (strategyBody s))
    forM_ strategies $ \s -> when (cyclic [strategyName s] (strategyName s))
      (Left (at (strategySpan s), "the strategy " ++ strategyName s ++ " uses itself; strategies may not be recursive"))
    let inline g = case g of
          GenNamed n -> maybe g (inline . strategyBody) (M.lookup n strategyTable)
          GenFrequency alternatives -> GenFrequency [(w, inline a) | (w, a) <- alternatives]
          GenSuchThat inner p n -> GenSuchThat (inline inner) p n
          GenBind x t from body -> GenBind x t (inline from) (inline body)
          _ -> g
    -- Laws: every name refers to a law of the served unit.
    let matching base = [n | n <- finalNames, lawBaseMatches abilityNames base n]
        ownLaw base = [l | l <- laws u ++ concatMap abilityLaws (abilities u), lawName l == base] ++
          [l | l <- laws u, lawBaseMatches abilityNames base (lawName l)]
    forM_ [(names, range) | HarnessFor names _ range <- items] $ \(names, range) -> forM_ names $ \base ->
      when (null (matching base))
        (Left (at range, "the harness " ++ harnessName h ++ " refers to the law `" ++ base ++ "`, but " ++ unitLabel ++
          " has no law of that name; a harness can only refer to the laws of the unit it serves"))
    -- Settings, wherever they appear.
    let allSettings = [(s, r) | HarnessDefault s r <- items] ++ [sr | HarnessFor _ ss _ <- items, sr <- ss]
    forM_ allSettings $ \(setting, range) -> case setting of
      TestWith names -> forM_ names $ \n -> unless (n == "native" || n `elem` handlerNames)
        (Left (at range, "test with " ++ n ++ ": " ++ unitLabel ++ " has no handler called " ++ n ++
          "; a harness tests laws with the unit's lawful handlers: " ++ intercalate ", " ("native" : handlerNames)))
      UseStrategy s _ -> unless (M.member s strategyTable)
        (Left (at range, "use " ++ s ++ ": this harness has no strategy called " ++ s))
      _ -> pure ()
    forM_ [(ss, r) | HarnessDefault s r <- items, let ss = [s]] $ \(ss, range) -> forM_ ss $ \s -> case s of
      UseStrategy _ input -> Left (at range, "use ... for " ++ input ++ " names a law's input, so it belongs in a `for law` block")
      _ -> pure ()
    forM_ [(names, ss) | HarnessFor names ss _ <- items] $ \(names, ss) -> forM_ ss $ \(s, range) -> case s of
      UseStrategy _ input -> forM_ names $ \base -> forM_ (take 1 (ownLaw base)) $ \l ->
        unless (input `elem` lawInputs l)
          (Left (at range, "use ... for " ++ input ++ ": the law `" ++ base ++ "` has no input called " ++ input ++
            (case lawInputs l of [] -> " (it has no inputs)"; xs -> " (its inputs are " ++ intercalate ", " xs ++ ")")))
      _ -> pure ()
    -- Sharing: only a resource that declares reset.
    forM_ [(r, scope, range) | HarnessShare r scope range <- items] $ \(r, scope, range) ->
      case [reset | (n, reset, _) <- resourceStubs u, n == r] of
        [] -> Left (at range, "share " ++ r ++ ": " ++ unitLabel ++ " declares no resource called " ++ r)
        reset : _ -> unless reset
          (Left (at range, "share " ++ r ++ " per " ++ scopeName scope ++ ": " ++ r ++ " does not declare reset, so one law would " ++
            "see what another left in it, which changes what laws observe; declare `reset` in resource " ++ r ++ " to share it"))
    let benchmarks = [n | HarnessBenchmark n _ _ <- items]
    forM_ [(n, range) | HarnessBenchmark n _ range <- items] $ \(n, range) ->
      when (length (filter (== n) benchmarks) > 1) (Left (at range, "the benchmark `" ++ n ++ "` is declared twice"))
    -- One plan per law: the defaults, then each block that names it.
    let defaults = [(s, r) | HarnessDefault s r <- items]
        blocks final = [(names, ss) | HarnessFor names ss _ <- items, any (\b -> lawBaseMatches abilityNames b final) names]
        pinned final = nub [abilityTypeName (handlerAbility hd) | (base, uses) <- lawHandlers u
          , lawBaseMatches abilityNames base final, UseHandler n <- concatMap unwrap uses
          , hd <- handlerDeclarations u, handlerName hd == n]
        unwrap use = case use of UseRecording inner -> unwrap inner; other -> [other]
    plans <- forM (laws u) $ \l -> do
      let final = lawName l
          applicable = defaults ++ concat [[(s, r) | (s, r) <- ss] | (_, ss) <- blocks final]
          groupName = case [names | (names, _) <- blocks final, length names > 1] of
            names : _ -> Just (intercalate ", " names)
            [] -> Nothing
      plan <- foldlM (apply (strategyTable, inline)) (emptyPlan (harnessName h)) { planGroup = groupName } applicable
      let skipped = case [ns | (TestWith ns, _) <- applicable] of
            [] -> Nothing
            lists -> let allowed = last lists in excluded allowed (pinned final) (maybe [] id (lookup final (lawAssignments u)))
      when (planSkip plan /= Nothing && planKnownFailing plan /= Nothing)
        (Left (Just (location l), "the law `" ++ final ++ "` is marked both skip and known failing; choose one"))
      pure (final, case (planSkip plan, skipped) of
        (Nothing, Just reason) -> plan { planSkip = Just reason }
        _ -> plan)
    pure u { lawHarness = plans }
  where
    scopeName scope = case scope of SharePerGroup -> "group"; SharePerUnit -> "unit"; SharePerRun -> "run"
    lawInputs l = nub (forallNames (definition l) ++ map fst (parameters l))
    forallNames d = case d of
      Forall bound body -> map fst bound ++ forallNames body
      Implies _ body -> forallNames body
      And a b -> forallNames a ++ forallNames b
      _ -> []
    checkGen where' g = case g of
      GenFrequency alternatives -> mapM_ (checkGen where' . snd) alternatives
      GenSuchThat inner _ _ -> checkGen where' inner
      GenBind x _ from body -> do
        when (x == "it") (Left (where', "bind it: `it` names the value in `such that`; choose another name"))
        checkGen where' from >> checkGen where' body
      _ -> pure ()
    foldlM f z xs = case xs of
      [] -> pure z
      x : rest -> f z x >>= \z' -> foldlM f z' rest
    apply (table, inline) plan (setting, range) = case setting of
      UseStrategy s input -> case M.lookup s table of
        Just declaration
          | input `elem` [i | (i, _, _, _) <- planDraws plan] ->
              Left (Just (spanStart range), "two strategies are given for the input " ++ input)
          | otherwise -> pure plan { planDraws = planDraws plan ++ [(input, s, strategyType declaration, inline (strategyBody declaration))] }
        Nothing -> pure plan
      TestWith _ -> pure plan
      CoverSetting p label e -> pure plan { planCover = planCover plan ++ [(p, label, e)] }
      ClassifySetting e label -> pure plan { planClassify = planClassify plan ++ [(e, label)] }
      LabelSetting e -> pure plan { planLabels = planLabels plan ++ [e] }
      TargetMaximize e -> pure plan { planTarget = Just e }
      TagsSetting tags -> pure plan { planTags = nub (planTags plan ++ tags) }
      SkipSetting reason -> pure plan { planSkip = Just reason }
      KnownFailingSetting reason -> pure plan { planKnownFailing = Just reason }
      TimeoutSetting ms -> pure plan { planTimeout = Just ms }
      RepeatSetting n -> pure plan { planRepeat = n }
      RetryFlakySetting n -> pure plan { planRetries = n }
    -- The reason a law variant is left out by `test with`, if it is.
    excluded allowed pinned assignment =
      let out = [ (ability, name) | (ability, choice) <- assignment, abilityTypeName ability /= failAbilityName
                , abilityTypeName ability `notElem` pinned
                , let name = choiceName choice
                , let candidates = "native" : [handlerName hd | hd <- handlerDeclarations u, handlerAbility hd == ability]
                , let wanted = filter (`elem` candidates) allowed
                , not (null wanted), name `notElem` wanted ]
      in case out of
        [] -> Nothing
        (ability, name) : _ -> Just ("the harness tests " ++ prettyType ability ++ " with " ++
          intercalate ", " [n | n <- allowed, n == "native" || n `elem` [handlerName hd | hd <- handlerDeclarations u, handlerAbility hd == ability]] ++
          " only, not " ++ name)
    choiceName choice = case choice of
      ChooseProduction -> "native"
      ChooseSpec n -> n
      ChooseRecording inner -> choiceName inner
