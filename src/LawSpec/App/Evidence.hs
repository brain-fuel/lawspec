-- | lawspec evidence, and the native observations lawspec explain reads,
-- ported from the Node CLI's evidence command (bin/lawspec.mjs) and
-- native-evidence.mjs: how every obligation is discharged, with what the
-- recorded lawspec test results establish for it.
--
-- A recorded native attempt counts only while its inputs still match: the
-- compiler build, the target and machine profile, the generated files on
-- disk, the toolchain, the project's own files and the law's semantic key.
-- A stored timestamp alone establishes nothing, and native execution never
-- establishes a universal proof or a search's completeness. Everything the
-- legacy CLI reported is kept, in its order and with its texts; result keys
-- name the host that ran the core ("LawSpec.App.TestResults" hostIdentity).
-- ref:DEC-haskell-application-port ref:DEC-completed-run-attestation
module LawSpec.App.Evidence
  ( Observing (..),
    evidenceCommand,
    evidenceStatuses,
    readNativeObservations,
    attachNativeEvidence,
    nativeEvidenceText,
    harnessText,
    dependencyText,
    deepEqual,
    parsesAsDate,
  )
where

import Control.Monad (foldM, forM, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, gets, modify')
import Data.Char (isDigit, toUpper)
import Data.List (intercalate, isPrefixOf, isSuffixOf, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Scientific (toBoundedInteger, toRealFloat)
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Doctor (doctor)
import LawSpec.App.Files (artifactsFrom, planChanges, planWrites, readOptional, readOptionalDirectory)
import LawSpec.App.Json
import LawSpec.App.Test (environmentDigest, projectDigest, projectKey, readAttestation, recordedDigest)
import LawSpec.App.TestReports (toFixed)
import LawSpec.App.TestResults (Attempt (..), attestedKeys, lawKeys, presentationDigest, recordNativeAttempts)
import LawSpec.App.TestRuns (NativeRun (..), RunOptions (..), entryField, nativeInvocations)
import LawSpec.Host.Path (join)

-- | What reading the recorded native observations needs: the compile
-- input, the selected targets with their roots, the manifest's folder and
-- contents, the core's build digest and the host's identity.
data Observing = Observing
  { observingInput :: Json,
    observingTargets :: [(Json, FilePath)],
    observingConfigRoot :: FilePath,
    observingConfig :: Json,
    observingBuild :: String,
    observingHost :: String
  }

-- | Each obligation status, strongest first, with how check's summary
-- names it; lawspec evidence heads each section with it in capitals.
evidenceStatuses :: [(String, String)]
evidenceStatuses =
  [ ("proved", "proved"),
    ("exhaustively-checked", "exhaustively checked"),
    ("property-tested", "property tested"),
    ("measured", "measured"),
    ("runtime-checked", "runtime checked"),
    ("default-handler", "default handler"),
    ("assumed", "assumed / external"),
    -- A law-set check a laws-for block excuses, with its reason and expiry.
    ("exempted", "exempted"),
    -- A law a confirmed counterexample shows false; the build fails.
    ("refuted", "refuted"),
    -- The harness plane: an acknowledged discrepancy, a law whose last run
    -- was flaky, and a law whose tests it skips.
    ("known-discrepancy", "known discrepancy"),
    ("flaky", "flaky"),
    -- A law whose last run reached no guarded consequence.
    ("vacuous", "vacuous"),
    ("skipped", "skipped"),
    -- A law about an open history that the entries so far do not decide.
    ("pending", "pending"),
    ("planned", "planned"),
    ("not-verified", "not verified"),
    ("incomplete", "incomplete"),
    ("unsupported", "unsupported")
  ]

-- * JavaScript's reading of values

-- | value ?? fallback: a member that is neither absent nor null.
defined :: String -> Json -> Maybe Json
defined = entryField

-- | A member as a template literal shows it.
text :: String -> Json -> String
text key value = maybe "undefined" jsString (member key value)

truthy :: String -> Json -> Bool
truthy key value = maybe False isTruthy (member key value)

-- | A member whose value is truthy.
truthyMember :: String -> Json -> Maybe Json
truthyMember key value = case member key value of
  Just v | isTruthy v -> Just v
  _ -> Nothing

-- | A member that is an array, or the empty list (value ?? []).
list :: String -> Json -> [Json]
list key value = fromMaybe [] (defined key value >>= arrayOf)

-- | An object literal with members that may be undefined: those are left
-- out, as JSON.stringify leaves them out.
object :: [(String, Maybe Json)] -> Json
object fields = jsObject [(key, value) | (key, Just value) <- fields]

-- | {...value, ...fields}: a defined member replaces in place or is
-- appended; an undefined one is left out of what is written.
spread :: Json -> [(String, Maybe Json)] -> Json
spread value fields = foldl step value fields
  where
    step kept (key, Just v) = setMember key v kept
    step kept (key, Nothing) = dropMember key kept

-- | a === b over parsed JSON: primitives by value, undefined equal to
-- undefined, and never an object or array (each parse is a fresh one).
strictEqual :: Maybe Json -> Maybe Json -> Bool
strictEqual Nothing Nothing = True
strictEqual (Just a) (Just b) = case (a, b) of
  (JArray _, _) -> False
  (JObject _, _) -> False
  _ -> a == b
strictEqual _ _ = False

-- | util.isDeepStrictEqual over JSON: objects by their own members, in any
-- order, arrays element by element.
deepEqual :: Maybe Json -> Maybe Json -> Bool
deepEqual Nothing Nothing = True
deepEqual (Just a) (Just b) = equal a b
  where
    equal (JObject xs) (JObject ys) =
      length xs == length ys && all (\(key, x) -> maybe False (equal x) (lookup key ys)) xs
    equal (JArray xs) (JArray ys) = length xs == length ys && and (zipWith equal xs ys)
    equal x y = x == y
deepEqual _ _ = False

-- | Array.prototype.join: null and undefined elements are empty.
joinJs :: String -> [Json] -> String
joinJs separator items = intercalate separator [if item == JNull then "" else jsString item | item <- items]

-- | text.replace(pattern, replacement): the first occurrence only.
replaceFirst :: String -> String -> String -> String
replaceFirst pattern replacement = go
  where
    go [] = []
    go value@(c : rest)
      | pattern `isPrefixOf` value = replacement ++ drop (length pattern) value
      | otherwise = c : go rest

replaceAll :: String -> String -> String -> String
replaceAll pattern replacement = go
  where
    go [] = []
    go value@(c : rest)
      | pattern `isPrefixOf` value = replacement ++ go (drop (length pattern) value)
      | otherwise = c : go rest

-- | Whether Date.parse reads a stored time: the ISO 8601 forms
-- Date.prototype.toISOString and the attestation documents write (a date,
-- optionally a time with minutes, seconds and a fraction, and a zone).
parsesAsDate :: String -> Bool
parsesAsDate value = case value of
  '+' : rest -> extended 6 rest
  '-' : rest -> extended 6 rest && take 6 rest /= "000000"
  _ -> extended 4 value
  where
    extended width input =
      let (year, rest) = splitAt width input
       in length year == width && all isDigit year && monthPart rest
    monthPart rest = case rest of
      "" -> True
      '-' : a : b : more | twoDigits [a, b] 1 12 -> dayPart more
      _ -> False
    dayPart rest = case rest of
      "" -> True
      '-' : a : b : more | twoDigits [a, b] 1 31 -> timePart more
      _ -> False
    timePart rest = case rest of
      "" -> True
      'T' : a : b : ':' : c : d : more | twoDigits [a, b] 0 24 && twoDigits [c, d] 0 59 -> secondsPart more
      _ -> False
    secondsPart rest = case rest of
      ':' : a : b : more | twoDigits [a, b] 0 59 -> fractionPart more
      _ -> zonePart rest
    fractionPart rest = case rest of
      '.' : more | (digits@(_ : _), after) <- span isDigit more, not (null digits) -> zonePart after
      _ -> zonePart rest
    zonePart rest = case rest of
      "" -> True
      "Z" -> True
      [s, a, b, ':', c, d] | s `elem` ("+-" :: String) -> twoDigits [a, b] 0 23 && twoDigits [c, d] 0 59
      _ -> False
    twoDigits digits low high = all isDigit digits && let n = read digits :: Int in n >= low && n <= high

-- * Recorded native observations

-- | obligationTargets: what a manifest entry's tests discharge.
obligationTargets :: Json -> Json
obligationTargets entry =
  fromMaybe (JArray [JObject [("declaration", fromMaybe JNull (member "law" entry)), ("stage", JString "law")]]) (defined "obligations" entry)

runtimeStages :: [String]
runtimeStages =
  [ "law",
    "model",
    "linearizable",
    "sequentially consistent",
    "causally consistent",
    "eventually consistent",
    "restart",
    "scenario",
    "supervision"
  ]

-- | Archived observations are shown in the current vocabulary; their raw
-- attempts keep the original values for freshness and completion checks.
observationOutcome :: Json -> Json
observationOutcome = \case
  JString "known-failing" -> JString "known-discrepancy"
  other -> other

-- | What a recorded layout and wiring give: the current generated files
-- and each law's key, or why no recorded observation can be matched.
data Context
  = Matchable Json (M.Map String String)
  | Unmatchable Bool String

data Caches = Caches
  { cachedPlans :: M.Map String Json,
    cachedContexts :: M.Map String Context
  }

-- | readNativeObservations: one row for each selected native check of each
-- target with recorded attempts, saying whether its recorded observation
-- matches the current inputs, and for each recorded check no longer
-- selected. Nothing when no target recorded an attempt.
readNativeObservations :: (Monad m) => Observing -> [Json] -> Maybe Json -> Command m [Json]
readNativeObservations observing evidence attestation = do
  records <- forM (observingTargets observing) $ \(target, root) -> do
    let file = join (observingConfigRoot observing) (".lawspec/results/" ++ language target ++ "-" ++ projectKey root ++ ".json")
    grantRead [file]
    content <- readOptional file
    record <- either failWith pure (parseJson (fromMaybe "{}" content))
    pure (target, root, record)
  if not (any (\(_, _, record) -> not (null (objectMembers "attempts" record))) records)
    then pure []
    else concat <$> mapM (\record -> evalStateT (observeTarget observing evidence attestation record) (Caches M.empty M.empty)) records

objectMembers :: String -> Json -> [(String, Json)]
objectMembers key value = maybe [] members (defined key value)

language :: Json -> String
language target = maybe "" jsString (member "language" target)

observeTarget :: (Monad m) => Observing -> [Json] -> Maybe Json -> (Json, FilePath, Json) -> StateT Caches (Command m) [Json]
observeTarget observing evidence attestation (target, root, record) = do
  let attempts = objectMembers "attempts" record
      runs = objectMembers "laws" record
      attestations = objectMembers "attestations" record
      -- An attempt is keyed by the wiring of the attestation it ran under:
      -- the one named now, or else the one lawspec test stored for its run.
      wiredBy attempt = case attestation of
        Just named -> Just named
        Nothing -> case truthyMember "environment" attempt of
          Just environment -> defined (jsString environment) (JObject attestations)
          Nothing -> Nothing
      modes = nub [mode | (_, attempt) <- attempts, Just profile <- [member "profile" attempt], Just mode@(JBool _) <- [member "minify" profile]]
  base <- plan (fromMaybe (JBool False) (listToMaybe modes)) attestation
  let baseDiagnostics = list "diagnostics" base
  if not (null baseDiagnostics)
    then
      pure
        [ object
            [ ("target", Just (JString (language target))),
              ("root", Just (JString root)),
              ("freshness", Just (JString "unavailable")),
              ("outcome", Just (JString "incomplete")),
              ( "obligations",
                Just
                  ( JArray
                      [ object [("declaration", member "declaration" item), ("stage", member "stage" item)]
                      | item <- evidence,
                        Just (JString stage) <- [member "stage" item],
                        stage `elem` runtimeStages
                      ]
                  )
              ),
              ("reason", Just (JString ("Native generation is unavailable: " ++ intercalate "; " [text "message" d | d <- baseDiagnostics])))
            ]
        ]
    else do
      let expected = lastByKey [(text "law" entry, entry) | entry <- list "tests" base]
      selected <- forM expected $ \(identity, baseline) -> observeCheck attempts runs wiredBy identity baseline
      let unselected =
            [ object
                [ ("target", Just (JString (language target))),
                  ("root", Just (JString root)),
                  ("check", member "check" attempt),
                  ("attempt", Just attempt),
                  ("outcome", observationOutcome <$> member "outcome" attempt),
                  ("coverage", member "coverage" attempt),
                  ("freshness", Just (JString "not-selected")),
                  ("reason", Just (JString "This native check is not selected by the current configuration"))
                ]
            | (identity, attempt) <- attempts,
              identity `notElem` map fst expected,
              isJust (defined "check" attempt >>= defined "obligations" >>= arrayOf)
            ]
      pure (selected ++ unselected)
  where
    configRoot = observingConfigRoot observing
    build = observingBuild observing
    input = observingInput observing
    machineBits = member "machineBits" input
    -- new Map(entries): each key at its first place, with its last value.
    lastByKey pairs = [(key, last [value | (key', value) <- pairs, key' == key]) | key <- nub (map fst pairs)]
    slot minify wired = jsString minify ++ "\0" ++ maybe "" (\w -> maybe "" jsString (defined "run" w >>= defined "id")) wired
    plan minify wired = do
      let key = slot minify wired
      cached <- gets (M.lookup key . cachedPlans)
      case cached of
        Just planned -> pure planned
        Nothing -> do
          planned <-
            lift . call "planGeneration" . jsObject $
              members input
                ++ [("target", JString (language target))]
                ++ [(field, value) | field <- ["sourceDir", "testDir", "generatedSourceDir", "generatedTestDir", "release", "nativeBindings", "actors"], Just value <- [member field target]]
                ++ [("minify", minify)]
                ++ [("attestation", w) | Just w <- [wired], isTruthy w]
          modify' (\c -> c {cachedPlans = M.insert key planned (cachedPlans c)})
          pure planned
    context minify wired = do
      let key = slot minify wired
      cached <- gets (M.lookup key . cachedContexts)
      case cached of
        Just found -> pure found
        Nothing -> do
          generated <- plan minify wired
          result <-
            if not (null (list "diagnostics" generated))
              then pure (Unmatchable False "Native generation is unavailable for the recorded layout")
              else lift (matchable generated)
          modify' (\c -> c {cachedContexts = M.insert key result (cachedContexts c)})
          pure result
    matchable generated = do
      let files = list "files" generated
      pending <- planWrites root (artifactsFrom (JArray files)) ".lawspec/generated.json" (const False)
      if not (null (planChanges pending))
        then pure (Unmatchable True "Generated files differ from the recorded/current plan")
        else do
          report <- doctor target root files
          if member "ok" report /= Just (JBool True)
            then pure (Unmatchable False ("The current native environment could not be checked: " ++ text "message" report))
            else do
              environment <- environmentDigest (observingHost observing) root report (language target)
              if not (strictEqual (member "presentation" record) (Just (JString (presentationDigest files environment))))
                then pure (Unmatchable False "Current generated presentation has not passed native validation; run lawspec test")
                else do
                  let owned = [path' | file <- files, member "ownership" file == Just (JString "generated"), Just (JString path') <- [member "path" file]]
                  recorded <- recordedDigest (join configRoot "recorded")
                  project <- projectDigest root owned (language target) configRoot (fromMaybe (JArray []) (member "inputs" (observingConfig observing)))
                  pure (Matchable generated (lawKeys build target (fromMaybe JNull machineBits) (list "tests" generated) environment project recorded (attestedKeys generated)))
    -- Only a single ordinary-law observation can be re-associated with a
    -- renamed law; combined model methods keep their exact group identities.
    reassociated attempts wiredBy identity baseline = foldM step Nothing attempts
      where
        step found@(Just _) _ = pure found
        step Nothing (_, original) = do
          let check = fromMaybe JNull (defined "check" original)
              single = case defined "nativeGroup" check >>= arrayOf of
                Just [_] -> True
                _ -> False
          if member "outcome" original /= Just (JString "passed")
            || not single
            || not (deepEqual (member "obligations" check) (Just (JArray [object [("declaration", member "id" check), ("stage", Just (JString "law"))]])))
            || not (deepEqual (Just (obligationTargets baseline)) (Just (JArray [JObject [("declaration", JString identity), ("stage", JString "law")]])))
            then pure Nothing
            else do
              let minify = fromMaybe (JBool False) (member "profile" original >>= defined "minify")
              candidate0 <- context minify (wiredBy original)
              candidate <- case candidate0 of
                Unmatchable True _ -> context (JBool (not (isTruthy minify))) (wiredBy original)
                _ -> pure candidate0
              pure $ case candidate of
                Matchable _ keys
                  | strictEqual (JString <$> M.lookup identity keys) (member "key" original),
                    strictEqual (member "key" baseline) (member "planKey" original) ->
                      Just (original, object [("check", member "id" check), ("key", member "key" original), ("at", member "at" original)])
                _ -> Nothing
    observeCheck attempts runs wiredBy identity baseline = do
      (attempt, reuse) <- case lookup identity attempts of
        Just found | isTruthy found -> pure (Just found, Nothing)
        _ -> do
          found <- reassociated attempts wiredBy identity baseline
          pure (fst <$> found, snd <$> found)
      let row extra =
            object
              ( [ ("target", Just (JString (language target))),
                  ("root", Just (JString root)),
                  ("check", Just (JObject [("id", JString identity), ("obligations", obligationTargets baseline)])),
                  ("outcome", Just (observationOutcome (fromMaybe (JString "not-run") (attempt >>= defined "outcome")))),
                  ("coverage", member "coverage" baseline),
                  ("attempt", attempt)
                ]
                  ++ extra
              )
          because freshness reason = row [("freshness", Just (JString freshness)), ("reason", Just (JString reason))]
      case attempt of
        Nothing -> pure (because "not-run" "No completed native observation was recorded")
        Just recorded -> do
          let profile = fromMaybe (JObject []) (defined "profile" recorded)
          if not (strictEqual (member "target" profile) (Just (JString (language target))))
            || not (strictEqual (member "root" profile) (Just (JString root)))
            || not (strictEqual (member "machineBits" profile) machineBits)
            || not (strictEqual (member "build" profile) (Just (JString build)))
            || not (isBoolean (member "minify" profile))
            then pure (because "stale" "Compiler, target or machine profile differs")
            else do
              let minify = fromMaybe (JBool False) (member "minify" profile)
              current0 <- context minify (wiredBy recorded)
              -- Layout belongs to the artifact, not to the meaning of its old
              -- run: the other canonical layout counts only when it exactly
              -- matches what is on disk.
              current <- case current0 of
                Unmatchable True _ -> context (JBool (not (isTruthy minify))) (wiredBy recorded)
                _ -> pure current0
              case current of
                Unmatchable stale reason -> pure (because (if stale then "stale" else "unavailable") reason)
                Matchable generated keys -> do
                  let entry = listToMaybe [e | e <- list "tests" generated, member "law" e == Just (JString identity)]
                  case entry of
                    Just entry'
                      | strictEqual (member "key" recorded) (JString <$> M.lookup identity keys),
                        strictEqual (member "planKey" recorded) (member "key" entry'),
                        isJust reuse || deepEqual (member "check" recorded >>= member "obligations") (Just (obligationTargets entry')),
                        deepEqual (member "coverage" recorded) (member "coverage" entry') ->
                          lift (completion runs identity recorded reuse profile generated keys entry' row because)
                    _ -> pure (because "stale" "Specification, selection, bindings, native source or toolchain inputs differ")
    completion runs identity recorded reuse profile generated keys entry row because = do
      let check = fromMaybe JNull (member "check" recorded)
          observedEntry = case reuse of
            Just _ -> spread (jsObject (members entry ++ members check)) [("law", member "id" check), ("key", member "planKey" recorded)]
            Nothing -> entry
          observedLaw = text "law" observedEntry
          observedKeys = case reuse of
            Just _ -> M.fromList [(observedLaw, maybe "undefined" jsString (member "key" recorded))]
            Nothing -> keys
      invocations <- either failWith pure (nativeInvocations target [observedEntry] (RunOptions False "." Nothing False root Nothing "node" Nothing ""))
      let invocation = listToMaybe [candidate | candidate <- invocations, observedLaw `elem` [text "law" e | e <- runLaws candidate]]
          seed = member "seed" recorded
          validSeed = case seed of
            Just (JNumber n) -> case toBoundedInteger n :: Maybe Int of
              Just i -> i >= 0 && toInteger i <= 2 ^ (53 :: Int) - 1
              Nothing -> False
            Just (JString s) -> not (null s) && all isDigit s
            _ -> False
          at = case member "at" recorded of
            Just (JString s) | parsesAsDate s -> Just s
            _ -> Nothing
          tests = member "tests" recorded >>= arrayOf
          invocationRecord = fromMaybe JNull (defined "invocation" recorded)
          started = not (member "outcome" recorded == Just (JString "not-run") && member "command" invocationRecord == Just JNull)
          recomputed = do
            guard' validSeed
            at' <- at
            nativeRun <- invocation
            tests' <- tests
            lookup
              observedLaw
              ( recordNativeAttempts
                  (runLaws nativeRun)
                  (runMatches nativeRun)
                  JNull
                  tests'
                  (Attempt observedKeys (fromMaybe JNull seed) (member "ok" invocationRecord == Just (JBool True)) profile "" (if isJust reuse then [observedEntry] else list "tests" generated) at' started)
              )
          establishes = case recomputed of
            Just again ->
              member "outcome" again == member "outcome" recorded
                && deepEqual (member "check" again >>= member "nativeGroup") (member "check" recorded >>= member "nativeGroup")
            Nothing -> False
          run = defined identity (JObject runs)
          passed = member "outcome" recorded == Just (JString "passed")
          harness = case run of
            Just r
              | passed && strictEqual (member "key" r) (member "key" recorded) && (truthy "flaky" r || truthy "adequacy" r) ->
                  [("harness", Just (object [("flaky", if truthy "flaky" r then Just (JBool True) else Nothing), ("adequacy", truthyMember "adequacy" r)]))]
            _ -> []
          reason
            | isJust reuse = "Original native completion reused for the current semantic law; no fresh invocation is claimed"
            | passed = "Recorded native completion matches the current inputs"
            | member "outcome" recorded == Just (JString "not-run") = "The last run started no native process for this check"
            | otherwise = "Recorded native attempt matches the current inputs"
      pure $
        if not establishes
          then because "unavailable" "The stored observation does not establish the current native completion"
          else row ([("freshness", Just (JString "matching-inputs")), ("reused", reuse)] ++ harness ++ [("reason", Just (JString reason))])
    guard' condition = if condition then Just () else Nothing
    isBoolean = \case
      Just (JBool _) -> True
      _ -> False

-- | attachNativeEvidence: each obligation with the native rows that
-- discharge it, and a planned one completed, made vacuous or left
-- incomplete by what they establish.
attachNativeEvidence :: [Json] -> [Json] -> [Json]
attachNativeEvidence evidence observations = map attach evidence
  where
    subject item target = member "declaration" target == member "declaration" item && member "stage" target == member "stage" item
    targetsOf row = case defined "check" row of
      Just check -> fromMaybe [] (arrayOf (fromMaybe (obligationTargets (JObject [])) (defined "obligations" check)))
      Nothing -> list "obligations" row
    outcomeIs outcome row = member "outcome" row == Just (JString outcome)
    attach item =
      let rows = [row | row <- observations, any (subject item) (targetsOf row)]
          current = [row | row <- rows, member "freshness" row == Just (JString "matching-inputs")]
          failed = filter (outcomeIs "failed") current
          combinedFailure = any (\row -> length (fromMaybe [] (member "attempt" row >>= defined "check" >>= defined "nativeGroup" >>= arrayOf)) > 1) failed
          allCurrent = length current == length rows
          status
            | not (null failed) = if combinedFailure then "incomplete" else "failed"
            | allCurrent && all (outcomeIs "passed") current = "passed"
            | allCurrent && all (outcomeIs "skipped") current = "skipped"
            | allCurrent && all (outcomeIs "known-discrepancy") current = "known-discrepancy"
            -- No generated case reached a guarded consequence on some
            -- target: nothing there tested the claim.
            | any (outcomeIs "vacuous") current = "vacuous"
            | any (outcomeIs "passed") current = "partial"
            | any (\row -> outcomeIs "incomplete" row || outcomeIs "not-run" row) current = "incomplete"
            | all (\row -> member "freshness" row == Just (JString "not-selected")) rows = "not-selected"
            | any (\row -> member "freshness" row == Just (JString "stale")) rows = "stale"
            | otherwise = "unavailable"
          completeFinite =
            status == "passed"
              && all
                ( \row ->
                    (member "coverage" row >>= member "kind") == Just (JString "finite-inputs")
                      && (member "coverage" row >>= member "scopedQuantifiers") == Just (JBool False)
                )
                rows
          measurement = member "executionKind" item == Just (JString "measurement")
          measurements =
            [ object
                [ ("kind", Just (JString "native-check-duration")),
                  ("target", member "target" row),
                  ("root", member "root" row),
                  ("test", member "name" test),
                  ("seconds", Just seconds)
                ]
            | measurement,
              row <- current,
              test <- fromMaybe [] (member "attempt" row >>= defined "tests" >>= arrayOf),
              Just seconds@(JNumber n) <- [member "time" test],
              n >= 0
            ]
          scope = "Reported durations cover the native check, including harness overhead; exact operation timings are not exported by these runners."
          nativeEvidence =
            JObject
              ( [ ("kind", JString "native-conformance"),
                  ("status", JString status),
                  ("searchCompleteness", JString (if completeFinite then "complete-finite-inputs" else "not-established")),
                  ("observations", JArray rows)
                ]
                  ++ (if measurement then [("measurements", JArray measurements), ("measurementScope", JString scope)] else [])
              )
          -- flatMap: an array's elements, any other value itself.
          adequacy =
            concat
              [ case member "harness" row >>= defined "adequacy" of
                  Just (JArray items) -> items
                  Just value -> [value]
                  Nothing -> []
              | row <- current
              ]
          enriched = jsObject (members item ++ [("nativeEvidence", nativeEvidence)] ++ [("adequacy", JArray adequacy) | not (null adequacy)])
          planned = object [("status", member "status" item), ("reason", member "reason" item)]
          flaky = any (\row -> maybe False isTruthy (member "harness" row >>= member "flaky")) current
          targets = length (nub [text "target" row ++ "\0" ++ text "root" row | row <- rows])
          replaced newStatus reason = jsObject (members enriched ++ [("plannedEvidence", planned), ("status", JString newStatus), ("reason", JString reason)])
       in if null rows
            then item
            else
              if member "status" item /= Just (JString "planned")
                then enriched
                else case status of
                  "passed" ->
                    replaced
                      (if flaky then "flaky" else if measurement then "measured" else if completeFinite then "exhaustively-checked" else "property-tested")
                      ( "Recorded native checks completed for "
                          ++ show targets
                          ++ " requested target(s); "
                          ++ ( if measurement
                                 then "the performance budget was checked against the real clock. This is measurement evidence, not proof. " ++ scope
                                 else
                                   if completeFinite
                                     then "every finite input was checked."
                                     else "this is scoped native execution evidence, not a universal model or search proof."
                             )
                          ++ (if flaky then " Its last run failed, then passed on a retry." else "")
                      )
                  "vacuous" ->
                    replaced
                      "vacuous"
                      ( "Recorded native checks completed, but "
                          ++ intercalate
                            ", "
                            [ reach "reached" row ++ " of " ++ reach "cases" row ++ " generated cases reached the guarded consequence on " ++ text "target" row
                            | row <- current,
                              outcomeIs "vacuous" row
                            ]
                          ++ "; the claim behind the guard was not tested by generated cases."
                      )
                  _
                    | status `elem` ["failed", "incomplete"] ->
                        replaced
                          "incomplete"
                          ( if combinedFailure
                              then "A combined native method failed; the specific included logical check is not identified, and no successful conformance result is established."
                              else
                                if status == "failed"
                                  then "A recorded native implementation check failed; no successful conformance result is established."
                                  else "Native execution did not complete all selected checks; no successful conformance result is established."
                          )
                    | otherwise -> enriched
    reach key row = maybe "0" jsString (member "attempt" row >>= defined "reach" >>= defined key)

-- | Native conformance an evidence row carries, as lawspec evidence shows it.
nativeEvidenceText :: Json -> String
nativeEvidenceText item = case member "nativeEvidence" item of
  Just summary
    | isTruthy summary ->
        intercalate "\n" $
          ["Native conformance: " ++ text "status" summary ++ "; search completeness: " ++ text "searchCompleteness" summary]
            ++ ["Native check duration: " ++ text "test" m ++ " [" ++ text "target" m ++ "] " ++ text "seconds" m ++ " s" | m <- list "measurements" summary]
            ++ [jsString scope | Just scope <- [truthyMember "measurementScope" summary]]
            ++ [ text "target" row
                   ++ " ("
                   ++ text "root" row
                   ++ "): "
                   ++ text "outcome" row
                   ++ "; "
                   ++ text "freshness" row
                   ++ maybe "" (\a -> "; seed " ++ text "seed" a ++ "; " ++ text "at" a) (truthyMember "attempt" row)
                   ++ "; "
                   ++ text "reason" row
               | row <- observations summary
               ]
            ++ [ text "name" test ++ ": " ++ maybe "native test failed" jsString (firstPresent ["reason", "failure", "message"] test)
               | row <- observations summary,
                 test <- fromMaybe [] (member "attempt" row >>= defined "tests" >>= arrayOf),
                 member "status" test == Just (JString "failed")
               ]
            ++ [ "Native invocation output (scoped to that invocation):\n" ++ jsString output
               | row <- observations summary,
                 Just output <- [member "attempt" row >>= defined "invocation" >>= truthyMember "output"]
               ]
  _ -> ""
  where
    observations summary = fromMaybe [] (member "observations" summary >>= arrayOf)
    firstPresent keys value = listToMaybe [v | key <- keys, Just v <- [defined key value]]

-- * lawspec evidence

-- | What lawspec test last recorded for each law, across targets, the
-- environment attestations its runs were given, by run id, and the outcome
-- each law last had in each attested run (a failure outweighs a pass).
data LastRuns = LastRuns
  { lastRunsByLaw :: [(String, Json)],
    lastAttestations :: [(String, Json)],
    -- | Each run's outcome by law; an outcome that was undefined is kept as
    -- 'Nothing', which JSON leaves out.
    lastOutcomes :: [(String, [(String, Maybe Json)])]
  }

-- | Map.set over an association list: a key keeps its first place.
upsert :: String -> a -> [(String, a)] -> [(String, a)]
upsert key value kept
  | any ((== key) . fst) kept = [(k, if k == key then value else v) | (k, v) <- kept]
  | otherwise = kept ++ [(key, value)]

-- | The outcomes of one attested run, as the object the compiler takes.
outcomesObject :: [(String, Maybe Json)] -> Json
outcomesObject known = JObject [(law, value) | (law, Just value) <- known]

lastRuns :: (Monad m) => FilePath -> Command m LastRuns
lastRuns configRoot = do
  let folder = join configRoot ".lawspec/results"
  grantRead [folder]
  names <- fromMaybe [] <$> readOptionalDirectory folder
  foldM readRecord (LastRuns [] [] []) [name | name <- names, ".json" `isSuffixOf` name]
  where
    rank :: Maybe Json -> Int
    rank outcome = fromMaybe (-1) (lookup outcome (zip (map (Just . JString) ["passed", "known-discrepancy", "skipped", "vacuous", "incomplete", "failed"]) [0 ..]))
    readRecord state name = do
      content <- readOptional (join folder' name)
      recorded <- either failWith pure (parseJson (fromMaybe "{}" content))
      let attempts = objectMembers "attempts" recorded
          laws = objectMembers "laws" recorded
          attestations = foldl (\kept (identity, a) -> upsert identity a kept) (lastAttestations state) (objectMembers "attestations" recorded)
          outcome kept (identity, law, value) =
            let known = fromMaybe [] (lookup identity kept)
                current = join' (lookup law known)
                known' = if isNothing current || rank value > rank current then upsert law value known else known
             in upsert identity known' kept
          attempted = [(jsString environment, law, member "outcome" attempt) | (law, attempt) <- attempts, Just environment <- [truthyMember "environment" attempt]]
          passedRuns =
            [ (jsString environment, law, Just (JString "passed"))
            | (law, run) <- laws,
              Just environment <- [truthyMember "environment" run],
              not (strictEqual (lookup law attempts >>= member "environment") (Just environment))
            ]
          outcomes = foldl outcome (lastOutcomes state) (attempted ++ passedRuns)
          merge kept (law, run) =
            let known = fromMaybe (JObject []) (lookup law kept)
                passedOf value = maybe "" jsString (defined "passed" value)
                latest = if passedOf known > passedOf run then known else run
                nullish key a b = case defined key a of
                  Just value -> Just value
                  Nothing -> member key b
             in upsert
                  law
                  ( object
                      [ ("flaky", if truthy "flaky" known then member "flaky" known else member "flaky" run),
                        ("adequacy", nullish "adequacy" run known),
                        ("reach", nullish "reach" run known),
                        ("vacuous", member "vacuous" known),
                        ("passed", member "passed" latest),
                        ("seed", member "seed" latest),
                        ("environment", member "environment" latest)
                      ]
                  )
                  kept
          merged = foldl merge (lastRunsByLaw state) laws
          -- A law whose last attempt on a target was vacuous has no passing
          -- run there; it is vacuous whatever another target recorded.
          vacuous kept (law, attempt)
            | member "outcome" attempt == Just (JString "vacuous") =
                upsert law (spread (fromMaybe (JObject []) (lookup law kept)) [("vacuous", Just (JBool True)), ("reach", member "reach" attempt)]) kept
            | otherwise = kept
      pure (LastRuns (foldl vacuous merged attempts) attestations outcomes)
    folder' = join configRoot ".lawspec/results"
    join' = \case
      Just (Just value) -> Just value
      _ -> Nothing

-- | A refuted law fails the command, but evidence still lists it: the
-- diagnostics then only say which laws are refuted.
refutedOnly :: Json -> (Json, Bool)
refutedOnly result = case member "diagnostics" result >>= arrayOf of
  Just items@(_ : _)
    | all (\d -> member "code" d == Just (JString "refuted")) items,
      maybe False isTruthy (member "evidence" result) ->
        (jsObject (members result ++ [("refuted", JArray items), ("diagnostics", JArray [])]), True)
  _ -> (result, False)

-- | lawspec evidence, after the compile input is built: every obligation
-- with how it is discharged, its native evidence and the environments its
-- tests ran in; 1 when a law is refuted.
evidenceCommand :: (Monad m) => Invocation -> Arguments -> Json -> Observing -> Command m Int
evidenceCommand invocation arguments config observing = do
  let json = flag "json" arguments
      input = observingInput observing
      configRoot = observingConfigRoot observing
      wanted = case positional arguments of
        name : _ | not (null name) -> Just name
        _ -> Nothing
  -- An attestation named here, or in lawspec.edn, says where the tests
  -- ran; otherwise each law shows the attested run it last passed in. A
  -- named attestation of a run lawspec test recorded links each law to that
  -- run, with the outcome recorded for it, unless the document says the run
  -- has not completed.
  named <- (>>= \a -> if isTruthy a then Just a else Nothing) <$> readAttestation arguments config configRoot (invocationDirectory invocation)
  LastRuns runs attestations outcomes <- lastRuns configRoot
  let recorded = case named >>= member "run" >>= member "id" of
        Just (JString identity) -> lookup identity outcomes
        _ -> Nothing
  checked <-
    call
      "check"
      ( jsObject
          ( members input
              ++ maybe [] (\a -> [("attestation", a)] ++ [("attestedOutcomes", outcomesObject o) | Just o <- [recorded]]) named
          )
      )
  let (result', refuted) = refutedOnly checked
  result <- diagnostics json result'
  let checkedEvidence = list "evidence" result
  observations <- readNativeObservations observing checkedEvidence named
  let attached = attachNativeEvidence checkedEvidence observations
  (withEnvironments, environments) <-
    case named of
      Just _ -> pure (attached, [fromMaybe JNull (member "attestation" result)])
      Nothing -> foldM (attested runs outcomes) (attached, []) attestations
  -- Native bindings are configured per target; their obligations are added.
  bound <-
    fmap concat . forM (observingTargets observing) $ \(target, _) -> case member "nativeBindings" target of
      Nothing -> pure []
      Just bindings -> do
        boundResult <- call "check" (jsObject (members input ++ [("nativeBindings", bindings)])) >>= diagnostics json
        pure
          [ setMember "target" (JString (language target)) item
          | item <- list "evidence" boundResult,
            Just (JString stage) <- [member "stage" item],
            stage `elem` ["binding", "codec", "generator", "native-function"]
          ]
  let selected =
        [ item
        | item <- withEnvironments ++ bound,
          maybe True (\name -> obligationName item == name || member "owner" item == Just (JString name)) wanted
        ]
  when (isJust wanted && null selected) (failWith "No matching obligation")
  -- The last run's outcome (lawspec test): a law that failed, then passed
  -- on a retry, is flaky; what its generated cases covered is its adequacy.
  let evidence = map (lastRun runs) selected
      harnessed = [item | item <- evidence, truthy "harness" item || truthy "adequacy" item]
  if json
    then printJson (JArray evidence)
    else
      printLine . intercalate "\n\n" $
        [ map toUpper label ++ " (" ++ show (length items) ++ ")\n" ++ intercalate "\n" (map itemText items)
        | (status, label) <- evidenceStatuses,
          let items = [item | item <- evidence, member "status" item == Just (JString status)],
          not (null items)
        ]
          -- How each law is discharged: the harness plane, apart from what
          -- the laws say.
          ++ ["HARNESS (" ++ show (length harnessed) ++ ")\n" ++ intercalate "\n" (map harnessText harnessed) | not (null harnessed)]
          -- Where the tests ran: reporting only, so no status above changes.
          ++ map (environmentText evidence) environments
  pure (if refuted then 1 else 0)
  where
    input' = observingInput observing
    attested runs outcomes (evidence, environments) (identity, attestation) = do
      let laws = [law | (law, run) <- runs, member "environment" run == Just (JString identity)]
      if null laws
        then pure (evidence, environments)
        else do
          result <-
            call "check" (jsObject (members input' ++ [("attestation", attestation), ("attestedOutcomes", outcomesObject (fromMaybe [] (lookup identity outcomes)))]))
              >>= diagnostics (flag "json" arguments)
          let execution = truthy "execution" attestation
              fields =
                foldl
                  (\kept (k, v) -> upsert k v kept)
                  []
                  [ ( text "declaration" item,
                      -- Receipts predating execution states keep their
                      -- historical meaning. An explicit running or wired state
                      -- keeps the compiler's planned fields; a cached passing
                      -- law does not complete its environment run.
                      if not execution && not (truthy "against" item)
                        then
                          [ ("environment", member "plannedEnvironment" item),
                            ("environmentRun", member "plannedEnvironmentRun" item),
                            ("against", member "plannedAgainst" item),
                            ("environmentProviders", member "plannedEnvironmentProviders" item)
                          ]
                        else
                          [ (key, Just value)
                          | key <-
                              [ "environment",
                                "environmentRun",
                                "against",
                                "environmentProviders",
                                "environmentOutcome",
                                "plannedEnvironment",
                                "plannedEnvironmentRun",
                                "plannedAgainst",
                                "plannedEnvironmentProviders"
                              ],
                            Just value <- [member key item]
                          ]
                    )
                  | item <- list "evidence" result,
                    truthy "against" item || truthy "plannedAgainst" item,
                    member "declaration" item `elem` map (Just . JString) laws
                  ]
              evidence' =
                [ case lookup (text "declaration" item) fields of
                    Just added | member "stage" item == Just (JString "law") -> spread item added
                    _ -> item
                | item <- evidence
                ]
              attestationResult = fromMaybe (JObject []) (member "attestation" result)
              dependency d =
                let obligations = list "obligations" d
                    planned = list "plannedObligations" d
                    inLaws o = o `elem` map JString laws
                 in setMember
                      "plannedObligations"
                      (JArray (if execution then filter inLaws planned else []))
                      (setMember "obligations" (JArray (filter inLaws (if execution then obligations else nub (obligations ++ planned)))) d)
              environment = setMember "dependencies" (JArray (map dependency (fromMaybe [] (member "dependencies" attestationResult >>= arrayOf)))) attestationResult
          pure (evidence', environments ++ [environment])
    lastRun runs item
      | truthy "nativeEvidence" item = item
      | otherwise = case (if member "stage" item == Just (JString "law") then lookup (text "declaration" item) runs else Nothing) of
          Nothing -> item
          Just run
            | truthy "vacuous" run ->
                spread
                  item
                  ( [("reach", Just reach) | Just reach <- [truthyMember "reach" run]]
                      ++ ( if tested item
                             then
                               [ ("status", Just (JString "vacuous")),
                                 ( "reason",
                                   Just (JString (text "reason" item ++ "; in its last run " ++ reachOf "reached" run ++ " of " ++ reachOf "cases" run ++ " generated cases reached the guarded consequence"))
                                 )
                               ]
                             else []
                         )
                  )
            | otherwise ->
                spread
                  item
                  ( [("lastNativeRun", Just (object [("passed", member "passed" run), ("seed", member "seed" run)]))]
                      ++ [("adequacy", Just adequacy) | Just adequacy <- [truthyMember "adequacy" run]]
                      ++ [("reach", Just reach) | Just reach <- [truthyMember "reach" run]]
                      ++ ( if truthy "flaky" run && tested item
                             then [("status", Just (JString "flaky")), ("reason", Just (JString (text "reason" item ++ "; its last run failed, then passed on a retry")))]
                             else []
                         )
                  )
    tested item = member "status" item `elem` [Just (JString "property-tested"), Just (JString "exhaustively-checked")]
    reachOf key run = maybe "0" jsString (defined "reach" run >>= defined key)

obligationName :: Json -> String
obligationName item = replaceFirst "::law::" "::" (text "declaration" item)

-- | One obligation, as lawspec evidence lists it.
itemText :: Json -> String
itemText item =
  "  "
    ++ text "stage" item
    ++ " "
    ++ obligationName item
    ++ maybe "" (\t -> " [" ++ jsString t ++ "]") (truthyMember "target" item)
    ++ maybe "" (\claim -> ": " ++ text "text" claim) (truthyMember "claim" item)
    ++ "\n    "
    ++ text "reason" item
    ++ (if truthy "nativeEvidence" item then "\n    " ++ replaceAll "\n" "\n    " (nativeEvidenceText item) else "")
    ++ maybe "" (\run -> "\n    last native run passed at " ++ text "passed" run ++ " (seed " ++ text "seed" run ++ ")") (truthyMember "lastNativeRun" item)
    ++ maybe
      ""
      ( \against ->
          ( if truthy "environmentOutcome" item
              then "\n    " ++ text "environmentOutcome" item ++ " in completed run " ++ runId "environmentRun" ++ " in environment " ++ text "environment" item ++ executionText (member "environmentRun" item) ++ " against "
              else "\n    last recorded passing run in environment " ++ text "environment" item ++ " (run " ++ runId "environmentRun" ++ ") against "
          )
            ++ intercalate "; " (map dependencyText (fromMaybe [] (arrayOf against)))
      )
      (truthyMember "against" item)
    ++ maybe
      ""
      ( \against ->
          "\n    planned in environment "
            ++ text "plannedEnvironment" item
            ++ " (run "
            ++ runId "plannedEnvironmentRun"
            ++ executionText (member "plannedEnvironmentRun" item)
            ++ "; "
            ++ unlinkedText (member "plannedEnvironmentRun" item)
            ++ ") against "
            ++ intercalate "; " (map dependencyText (fromMaybe [] (arrayOf against)))
      )
      (truthyMember "plannedAgainst" item)
  where
    runId key = maybe "undefined" (text "id") (member key item)

-- | One attested environment, as lawspec evidence shows it.
environmentText :: [Json] -> Json -> String
environmentText evidence e =
  "ENVIRONMENT "
    ++ text "environment" e
    ++ " (run "
    ++ text "id" run
    ++ ", recorded "
    ++ text "recordedAt" run
    ++ executionText (member "run" e)
    ++ ")\n"
    ++ maybe
      ""
      ( \a ->
          "  architecture "
            ++ text "document" a
            ++ " "
            ++ text "digest" a
            ++ maybe "" (\t -> ", topology " ++ jsString t) (truthyMember "topologyDigest" a)
            ++ "\n"
      )
      (truthyMember "architecture" e)
    ++ maybe
      ""
      ( \a ->
          let implementation = fromMaybe JNull (member "implementation" a)
           in "  application "
                ++ text "node" a
                ++ ": "
                ++ ( case truthyMember "component" a of
                       Just c -> "component " ++ text "name" c ++ " " ++ text "version" c ++ " (" ++ text "fingerprint" c ++ "); "
                       Nothing -> let c = fromMaybe JNull (member "contract" a) in "contract " ++ text "package" c ++ " " ++ text "version" c ++ "; "
                   )
                ++ text "kind" implementation
                ++ " "
                ++ text "product" implementation
                ++ " "
                ++ text "version" implementation
                ++ maybe "" (\c -> " (commit " ++ jsString c ++ ")") (truthyMember "commit" implementation)
                ++ "\n"
      )
      (truthyMember "application" e)
    ++ intercalate "\n" (map dependencyLine (fromMaybe [] (member "dependencies" e >>= arrayOf)))
  where
    run = fromMaybe JNull (member "run" e)
    outcome o = listToMaybe [value | item <- evidence, member "declaration" item == Just o, Just value <- [truthyMember "environmentOutcome" item]]
    dependencyLine d =
      let obligations = list "obligations" d
          failed = length [() | o <- obligations, outcome o `elem` [Just (JString "failed"), Just (JString "incomplete")]]
          planned = list "plannedObligations" d
       in "  "
            ++ dependencyText d
            ++ "; "
            ++ ( if not (null obligations)
                   then show (length obligations) ++ " tested obligation(s)" ++ (if failed > 0 then ", " ++ show failed ++ " failed" else "")
                   else
                     if not (null planned)
                       then show (length planned) ++ " planned obligation(s); " ++ unlinkedText (member "run" e)
                       else "no tested obligation relies on it"
               )

-- | One attested dependency, as lawspec evidence shows it.
dependencyText :: Json -> String
dependencyText d =
  text "dependency" d
    ++ ": "
    ++ maybe
      "real"
      ( \standIn ->
          "stand-in "
            ++ text "identity" standIn
            ++ " "
            ++ text "version" standIn
            ++ " ("
            ++ level (text "conformance" standIn)
            ++ maybe "" (\h -> ", history " ++ jsString h ++ (if member "historyFrom" ran == Just (JString "completed") then " when completed" else "")) (history >>= \h -> if isTruthy h then Just h else Nothing)
            ++ ")"
      )
      (truthyMember "standIn" d)
    ++ " at "
    ++ text "endpoint" d
    ++ (if truthy "reached" d then "" else " (not reached when recorded)")
    ++ maybe "" (\i -> "; " ++ text "kind" i ++ " " ++ text "product" i ++ " " ++ text "version" i) (truthyMember "implementation" d)
    ++ maybe "" (\c -> "; contract " ++ text "package" c ++ " " ++ text "version" c) (truthyMember "contract" d)
    ++ maybe "" (\n -> "; node " ++ jsString n ++ maybe "" (\e -> " via " ++ jsString e) (truthyMember "edge" d)) (truthyMember "node" d)
    ++ ( case truthyMember "completed" d of
           Just c | not (truthy "reached" c) -> " (not reached when completed)"
           _ -> ""
       )
  where
    level c = if not (null c) && all isDigit c then "conformance level " ++ c else "conformance " ++ c
    ran = fromMaybe (JObject []) (defined "ranAgainst" d)
    history = case defined "historyDigest" ran of
      Just h -> Just h
      Nothing -> defined "standIn" d >>= defined "historyDigest"

-- | What an attested run's document records, as lawspec evidence shows it.
executionText :: Maybe Json -> String
executionText run = case run >>= truthyMember "execution" of
  Nothing -> ""
  Just e
    | member "status" e == Just (JString "completed") -> ", completed with exit code " ++ text "exitCode" e
    | member "status" e == Just (JString "running") -> ", in progress"
    | otherwise -> ", wiring only"

-- | Why a law relying on an attested dependency has no completed run linked.
unlinkedText :: Maybe Json -> String
unlinkedText run = case run >>= defined "execution" >>= member "status" of
  Just (JString "wired") -> "wiring only; nothing ran"
  Just (JString "running") -> "run in progress; no completed run linked"
  _ -> "no completed run linked"

-- | One law's harness, as lawspec evidence shows it.
harnessText :: Json -> String
harnessText item =
  intercalate "\n" $
    ("  " ++ obligationName item ++ ": " ++ (if null parts then "no harness settings" else intercalate "; " parts))
      : concatMap adequacyLines (list "adequacy" item)
  where
    h = fromMaybe (JObject []) (defined "harness" item)
    parts =
      ["harness " ++ text "unit" h | truthy "unit" h]
        ++ ["tags " ++ joinJs ", " tags | Just (JArray tags@(_ : _)) <- [member "tags" h]]
        ++ [intercalate ", " [text "input" s ++ " drawn by " ++ text "strategy" s | s <- strategies] | Just (JArray strategies@(_ : _)) <- [member "strategies" h]]
        ++ ["cover " ++ text "percent" c ++ "% \"" ++ text "label" c ++ "\" when " ++ whenText c | c <- list "cover" h]
        ++ ["classify " ++ whenText c ++ " as \"" ++ text "label" c ++ "\"" | c <- list "classify" h]
        ++ ["label " ++ text "text" l | l <- list "labels" h]
        ++ ["target maximize " ++ text "text" t | Just t <- [truthyMember "target" h]]
        ++ ["timeout " ++ text "timeoutMilliseconds" h ++ " ms" | truthy "timeoutMilliseconds" h]
        ++ ["repeat " ++ text "repeat" h | Just (JNumber n) <- [member "repeat" h], n > 1]
        ++ ["retry flaky " ++ text "retries" h | truthy "retries" h]
        ++ ["skip \"" ++ text "skip" h ++ "\"" | truthy "skip" h]
        ++ ["known discrepancy \"" ++ text "knownDiscrepancy" h ++ "\"" | truthy "knownDiscrepancy" h]
        ++ ["order random" | truthy "orderRandom" h]
        ++ ["parallel" | truthy "parallel" h]
    whenText c = maybe "undefined" (text "text") (member "when" c)
    adequacyLines run =
      let cases = member "cases" run
          counts = jsObject (objectMembers "classes" run ++ [("label " ++ k, v) | (k, v) <- objectMembers "labels" run])
          percent v = case cases of
            Just (JNumber n) | n /= 0 -> toFixed 1 (100 * number v / toRealFloat n)
            _ -> "0"
          number = \case
            JNumber n -> toRealFloat n
            _ -> 0 / 0
       in ( "    last run: "
              ++ text "cases" run
              ++ " generated case(s)"
              ++ concat
                [ "; cover \"" ++ text "label" c ++ "\" " ++ text "observed" c ++ "% (needs " ++ text "required" c ++ "%)" ++ (if truthy "met" c then "" else " NOT MET")
                | c <- list "cover" run
                ]
          )
            : ["    " ++ intercalate ", " [k ++ ": " ++ percent v ++ "%" | (k, v) <- members counts] | not (null (members counts))]
