-- | What lawspec test records, ported from the Node CLI's test-command.mjs,
-- replay.mjs and native-evidence.mjs: each law's result key, which laws run
-- again, the batches a run is made of (a failing law is replayed first with
-- the seed that exposed it), the attempt recorded for each law, reach, and
-- the failure database after a run. Everything here is pure; objects keep
-- the member order the Node CLI gave them, since the results file is JSON.
--
-- A law's result is keyed by what it does (its plan key, the semantic hash
-- of the law and what it reaches), the core's build, the target's
-- configuration, the toolchain the doctor reports, the host that runs the
-- core and, for a law that calls adapters, every file in the project that
-- LawSpec did not generate and the recorded values. Never the generated
-- files' bytes: a reformat reruns nothing. ref:DEC-content-identity
-- ref:DEC-haskell-application-port ref:DEC-s1j-shared-failures
module LawSpec.App.TestResults
  ( hostIdentity,
    nativeSeed,
    lawKeys,
    previousResult,
    testsToRun,
    selectByTags,
    presentationDigest,
    Batch (..),
    planBatches,
    Progress (..),
    startBatch,
    afterInvocation,
    continueRun,
    recordFailures,
    ownFailure,
    batchSummaries,
    ranText,
    Attempt (..),
    recordNativeAttempts,
    lawReach,
    applyReach,
    reachText,
    attestedKeys,
    lawId,
    assign,
  )
where

import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Scientific (Scientific, toBoundedInteger)
import LawSpec.App.Command (HostIdentity (..), utf8)
import LawSpec.App.Json
import LawSpec.App.TestRuns (entryField, entryText)
import LawSpec.Digest (digest, digestHex)

sha :: String -> String
sha = digestHex . digest . utf8

-- | A law's identity in the manifest (entry.law).
lawId :: Json -> String
lawId = entryText "law"

-- | Object.assign(target, source) over member lists: a member already
-- present keeps its place and takes the new value; others are appended.
assign :: [(String, Json)] -> [(String, Json)] -> [(String, Json)]
assign target source = foldl set target source
  where
    set kept (key, value)
      | any ((== key) . fst) kept = [(k, if k == key then value else v) | (k, v) <- kept]
      | otherwise = kept ++ [(key, value)]

-- | The identity of the host the native tests ran under, in place of the
-- legacy CLI's fingerprint of the Node binary and SDK files (native-host.mjs):
-- the host's kind and version and the core's digest.
hostIdentity :: Maybe HostIdentity -> String -> String
hostIdentity host build =
  sha
    ( "lawspec-native-host-v2\0"
        ++ compact
          ( JArray
              [ JString (maybe "unknown" hostKind host),
                JString (maybe "" hostVersion host),
                JString build
              ]
          )
    )

-- | nativeSeed: a whole-number seed, as a number while it is exact.
nativeSeed :: Json -> Either String Json
nativeSeed value
  | null text || not (all (`elem` ['0' .. '9']) text) = Left "A native seed must be a whole number"
  | JNumber n <- value, not (safe n) = Left "The recorded numeric seed lost precision; rerun with an explicit exact seed"
  | otherwise = Right (if wholeSafe then JNumber (fromInteger (read text)) else JString text)
  where
    text = jsString value
    limit = 2 ^ (53 :: Int) - 1 :: Integer
    safe n = case toBoundedInteger n :: Maybe Int of
      Just i -> abs (toInteger i) <= limit
      Nothing -> False
    -- Number(text) is a safe integer: below 2^53 once rounded to a double.
    wholeSafe = (read text :: Integer) <= limit

-- | lawKeys: each law's result key.
lawKeys :: String -> Json -> Json -> [Json] -> String -> String -> String -> [(String, String)] -> M.Map String String
lawKeys build target machineBits tests environment project recorded attested =
  M.fromList
    [ ( lawId entry,
        sha
          ( compact
              ( JArray
                  ( [ JString build,
                      JString (configuration entry),
                      machineBits,
                      fromMaybe JNull (member "key" entry),
                      JString environment,
                      if native entry then JString project else JNull,
                      if native entry then JString recorded else JNull
                    ]
                      ++ [JString wiring | Just wiring <- [lookup (lawId entry) attested]]
                  )
              )
          )
      )
    | entry <- tests
    ]
  where
    -- The compiler resolves binding reachability per law; a missing flag
    -- stays conservative.
    native entry = member "callsAdapters" entry /= Just (JBool False)
    configuration entry = compact (JObject [(key, value) | (key, value) <- members target, key /= "root", native entry || key /= "nativeBindings"])

-- | A law's last result: under its identity, or, when the law was renamed,
-- under any earlier identity with the same key.
previousResult :: [(String, Json)] -> String -> Maybe String -> Maybe Json
previousResult previous law key = case lookup law previous of
  Just result | keyOf result == key -> Just result
  _ -> case [result | (_, result) <- previous, keyOf result == key] of
    result : _ -> Just result
    [] -> Nothing
  where
    keyOf result = case member "key" result of
      Just (JString k) -> Just k
      Just _ -> Just "\0not a string"
      Nothing -> Nothing

-- | Laws selected by tag: every --tag, and none of --exclude-tag.
selectByTags :: [Json] -> [String] -> [String] -> [Json]
selectByTags entries include exclude =
  [ entry
  | entry <- entries,
    let tags = [tag | Just (JArray items) <- [member "tags" entry], JString tag <- items],
    null include || any (`elem` tags) include,
    not (any (`elem` tags) exclude)
  ]

-- | The laws that run: every one with --fresh, --coverage or
-- --update-recorded, one with a recorded failure, and one whose key has no
-- passing result.
testsToRun :: [Json] -> M.Map String String -> [(String, Json)] -> [(String, Json)] -> Bool -> [Json]
testsToRun entries keys previous failures everything =
  [ entry
  | entry <- entries,
    everything
      || maybe False isTruthy (lookup (lawId entry) failures)
      || not (isJust (previousResult previous (lawId entry) (M.lookup (lawId entry) keys)))
  ]

-- | Which current generated files have passed native source validation.
presentationDigest :: [Json] -> String -> String
presentationDigest files environment =
  sha
    ( compact
        ( JArray
            [ JString environment,
              JArray
                [ JArray [fromMaybe JNull (member "path" file), fromMaybe JNull (member "content" file)]
                | file <- files,
                  member "ownership" file == Just (JString "generated")
                ]
            ]
        )
    )

-- | One batch of a run: its seed, whether it replays a recorded failure,
-- and its laws.
data Batch = Batch {batchSeed :: String, batchReplay :: Bool, batchEntries :: [Json]}

-- | planBatches: one replay batch per recorded seed, in the order the seeds
-- first appear, then every other law with the fresh seed. Without replay
-- (an explicit --seed) every law runs with that seed.
planBatches :: [Json] -> [(String, Json)] -> String -> Bool -> Either String [Batch]
planBatches stale database seed replay = do
  seeds <- mapM (\entry -> replaySeed (lawId entry) (lookup (lawId entry) database)) replayed
  let batches =
        [Batch recorded True [entry | (entry, s) <- zip replayed seeds, s == recorded] | recorded <- nub seeds]
          ++ [Batch seed False [entry | entry <- stale, lawId entry `notElem` map lawId replayed]]
  pure (filter (not . null . batchEntries) batches)
  where
    replayed = if replay then [entry | entry <- stale, maybe False isTruthy (lookup (lawId entry) database)] else []
    replaySeed law entry =
      let text = maybe "undefined" (\e -> maybe "undefined" jsString (member "seed" e)) entry
       in if not (null text) && all (`elem` ['0' .. '9']) text
            then Right text
            else Left ("The failure database holds no whole-number seed for " ++ law)

-- | What one batch has shown so far.
data Progress = Progress {progressFailed :: Bool, progressExecuted :: Int}

startBatch :: Progress
startBatch = Progress False 0

-- | One invocation of a batch has ended: the progress, whether the
-- invocation failed, and whether the batch goes on. A failed invocation in
-- which no law's test executed could not start, so the rest of its batch
-- is not started.
afterInvocation :: Progress -> Bool -> [Json] -> Int -> (Progress, Bool, Bool)
afterInvocation progress ok tests lawTests =
  (Progress (progressFailed progress || failed) (progressExecuted progress + lawTests), failed, not failed || lawTests > 0)
  where
    failed = not ok || any ((== Just (JString "failed")) . member "status") tests

-- | Only a failed batch in which no law's test executed stops the run.
continueRun :: Progress -> Bool
continueRun progress = not (progressFailed progress) || progressExecuted progress > 0

-- | The mark on a database entry written by the current rule: the law's
-- own tests failed with the entry's seed.
ownFailure :: String
ownFailure = "own-tests-failed"

-- | recordFailures: the failure database after a run.
recordFailures :: [(String, Json)] -> [Json] -> [String] -> [(String, Json)] -> String -> [(String, Json)]
recordFailures database stale passed attempts at = foldl step database stale
  where
    step next entry
      | law `elem` passed = remove next
      | Just attempt <- lookup law attempts,
        member "outcome" attempt == Just (JString "failed") =
          assign next [(law, JObject [("seed", fromMaybe JNull (member "seed" attempt)), ("failed", JString at), ("cause", JString ownFailure)])]
      | Just recorded <- lookup law next,
        isTruthy recorded,
        member "cause" recorded /= Just (JString ownFailure),
        Just attempt <- lookup law attempts,
        Just (JArray (_ : _)) <- member "tests" attempt =
          remove next
      | otherwise = next
      where
        law = lawId entry
        remove = filter ((/= law) . fst)

-- | What each batch did, for the summary.
batchSummaries :: [Batch] -> [(String, Json)] -> [Json]
batchSummaries batches attempts =
  [ JObject
      ( [ ("seed", JString (batchSeed batch)),
          ("replay", JBool (batchReplay batch)),
          ("ran", JArray [JString (lawId entry) | entry <- batchEntries batch, lawId entry `notElem` unstarted])
        ]
          ++ [("notRun", JArray (map JString unstarted)) | not (null unstarted)]
      )
  | batch <- batches,
    let unstarted = [lawId entry | entry <- batchEntries batch, (lookup (lawId entry) attempts >>= member "outcome") == Just (JString "not-run")]
  ]

-- | "ran 3 law(s) with seed 7", or each batch's own seed when there are
-- several.
ranText :: [Json] -> String
ranText summaries = case active of
  [] -> "ran 0 law(s)"
  [one] -> "ran " ++ show total ++ " law(s) with seed " ++ seedOf one
  _ ->
    "ran "
      ++ show total
      ++ " law(s): "
      ++ joinComma
        [ show (length (ranOf batch)) ++ " " ++ (if member "replay" batch == Just (JBool True) then "replayed " else "") ++ "with seed " ++ seedOf batch
        | batch <- active
        ]
  where
    ranOf batch = fromMaybe [] (member "ran" batch >>= arrayOf)
    active = filter (not . null . ranOf) summaries
    total = sum (map (length . ranOf) active)
    seedOf batch = maybe "undefined" jsString (member "seed" batch)
    joinComma [] = ""
    joinComma items = foldr1 (\a b -> a ++ ", " ++ b) items

-- | What recordNativeAttempts needs to know of the run.
data Attempt = Attempt
  { attemptKeys :: M.Map String String,
    attemptSeed :: Json,
    attemptOk :: Bool,
    attemptProfile :: Json,
    attemptOutput :: String,
    attemptAll :: [Json],
    attemptAt :: String,
    -- | False for a law no native process was started for: not-run says
    -- less than incomplete (started, not completed).
    attemptStarted :: Bool
  }

-- | recordNativeAttempts: each law's attempt, from the tests its run's
-- report shows. Native execution observations are scoped to the test
-- slots that completed; they never establish a proof or a search's
-- completeness.
recordNativeAttempts :: [Json] -> Maybe (Json -> [Json]) -> Json -> [Json] -> Attempt -> [(String, Json)]
recordNativeAttempts laws matches command tests settings =
  [ (lawId entry, attemptOf entry)
  | entry <- laws
  ]
  where
    attemptOf entry =
      let matched = [test | test <- tests, Just match <- [matches], lawId entry `elem` map lawId (match test)]
          statusIs status test = member "status" test == Just (JString status)
          model = maybe False (not . null) (member "obligations" entry >>= arrayOf)
          complete = not (null matched) && all (statusIs "passed") matched && (attemptOk settings || model)
          truthy key = maybe False isTruthy (member key entry)
          outcome
            | any (statusIs "failed") matched = "failed"
            | any (statusIs "incomplete") matched = "incomplete"
            | truthy "skip" = "skipped"
            | complete = if truthy "knownDiscrepancy" then "known-discrepancy" else "passed"
            | not (null matched) && all (statusIs "skipped") matched = "skipped"
            | attemptStarted settings || not (null matched) = "incomplete"
            | otherwise = "not-run"
          explained test = statusIs "failed" test && any (\key -> maybe False isTruthy (member key test)) ["failure", "reason", "message"]
          keepOutput = not (attemptOk settings) && outcome `elem` ["failed", "incomplete"] && not (null (attemptOutput settings)) && not (any explained matched)
       in jsObject
            ( [("key", JString key) | Just key <- [M.lookup (lawId entry) (attemptKeys settings)]]
                ++ [("planKey", key) | Just key <- [member "key" entry]]
                ++ [ ("seed", attemptSeed settings),
                     ("at", JString (attemptAt settings)),
                     ("outcome", JString outcome),
                     ("profile", attemptProfile settings),
                     ("coverage", fromMaybe (JObject [("kind", JString "sampled"), ("scopedQuantifiers", JBool True)]) (entryField "coverage" entry)),
                     ( "check",
                       jsObject
                         ( [("id", v) | Just v <- [member "law" entry]]
                             ++ [("unit", v) | Just v <- [member "unit" entry]]
                             ++ [("file", v) | Just v <- [member "file" entry]]
                             ++ [("name", v) | Just v <- [member "name" entry]]
                             ++ [("label", v) | Just v <- [member "label" entry]]
                             ++ [("scope", v) | Just v <- [member "scope" entry], isTruthy v]
                             ++ [ ("obligations", fromMaybe (JArray [JObject [("declaration", fromMaybe JNull (member "law" entry)), ("stage", JString "law")]]) (entryField "obligations" entry)),
                                  ( "nativeGroup",
                                    JArray
                                      [ fromMaybe JNull (member "law" other)
                                      | other <- attemptAll settings,
                                        member "file" other == member "file" entry,
                                        member "name" other == member "name" entry,
                                        member "scope" other == member "scope" entry
                                      ]
                                  )
                                ]
                         )
                     ),
                     ("tests", JArray matched),
                     ("invocation", JObject ([("ok", JBool (attemptOk settings)), ("command", command)] ++ [("output", JString (attemptOutput settings)) | keepOutput])),
                     ("verification", JString "native-execution"),
                     ("searchCompleteness", JString "not-established")
                   ]
            )

-- | Reach: how many of a guarded law's generated cases satisfied each guard
-- of its claim, summed over the statistics its tests wrote. A guarded law
-- without counts is unknown, never measured.
lawReach :: Json -> [Json] -> Maybe Json
lawReach entry statistics
  | null rows =
      case entryField "reach" entry of
        Just reach
          | maybe False isTruthy (member "guards" reach) ->
              Just
                ( JObject
                    [ ("status", JString "unknown"),
                      ( "reason",
                        JString
                          ( if maybe False isTruthy (member "measured" reach)
                              then "the run recorded no reach counts for this law"
                              else "this target does not count reached consequences"
                          )
                      )
                    ]
                )
        _ -> Nothing
  | otherwise =
      Just
        ( JObject
            [ ("status", JString "measured"),
              ("cases", JNumber (maybe 0 fst (headMaybe sites))),
              ("reached", if null sites then JNull else JNumber (minimum (map snd sites))),
              ("sites", JArray [JObject [("evaluated", JNumber e), ("held", JNumber h)] | (e, h) <- sites])
            ]
        )
  where
    rows = [reach | row <- statistics, member "law" row == member "label" entry, Just (JArray reach) <- [member "reach" row]]
    width = maximum (0 : map length rows)
    sites = [(total "evaluated" index, total "held" index) | index <- [0 .. width - 1]]
    total :: String -> Int -> Scientific
    total key index = sum [number (member key site) | row <- rows, (i, site) <- zip [0 ..] row, i == index]
    number = \case
      Just (JNumber n) -> n
      _ -> 0
    headMaybe = \case
      x : _ -> Just x
      [] -> Nothing

-- | applyReach: each run law's reach, and a passed law none of whose
-- generated cases reached its guarded consequence made vacuous. The
-- attempts after, and the vacuous laws.
applyReach :: [(String, Json)] -> [Json] -> [Json] -> ([(String, Json)], [Json])
applyReach attempts entries statistics = foldl step (attempts, []) entries
  where
    step (kept, vacuous) entry = case (lookup (lawId entry) kept, lawReach entry statistics) of
      (Just attempt, Just reach) ->
        let measured = member "status" reach == Just (JString "measured")
            cases = case member "cases" reach of
              Just (JNumber n) -> n
              _ -> 0
            reached = member "reached" reach == Just (integer 0)
            isVacuous = member "outcome" attempt == Just (JString "passed") && measured && cases > 0 && reached
            attempt' = setMember "reach" reach attempt
            attempt'' = if isVacuous then setMember "outcome" (JString "vacuous") attempt' else attempt'
         in (assign kept [(lawId entry, attempt'')], if isVacuous then vacuous ++ [entry] else vacuous)
      _ -> (kept, vacuous)

-- | One line per guarded law, with the compiler's suggestion under a
-- vacuous one.
reachText :: Json -> Maybe Json -> [String]
reachText entry attempt = case attempt >>= member "reach" of
  Nothing -> []
  Just reach
    | member "status" reach /= Just (JString "measured") ->
        ["  " ++ entryText "label" entry ++ ": reach unknown (" ++ maybe "undefined" jsString (member "reason" reach) ++ ")"]
    | otherwise ->
        let line = "  " ++ entryText "label" entry ++ ": " ++ field "reached" reach ++ " of " ++ field "cases" reach ++ " generated cases reached the consequence"
         in if (attempt >>= member "outcome") == Just (JString "vacuous")
              then (line ++ " \x2014 VACUOUS") : ["    " ++ maybe "undefined" jsString (member "message" advice) | Just (JArray advices) <- [entryField "reach" entry >>= entryField "advice"], advice <- advices]
              else [line]
  where
    field key value = maybe "undefined" jsString (member key value)

-- | attestedKeys: each law an attestation touches, by how its dependencies
-- were wired (endpoint, kind, and a stand-in's product, version and
-- conformance); what the run observed changes no key.
attestedKeys :: Json -> [(String, String)]
attestedKeys planned =
  -- A Map keeps the last value set for a declaration; only lookups use it.
  M.toList . M.fromList $
    [ ( maybe "undefined" jsString (member "declaration" item),
        compact
          ( JArray
              [ fromMaybe JNull (firstPresent ["environment", "plannedEnvironment"] item),
                JArray (map wiring (fromMaybe [] (firstPresent ["against", "plannedAgainst"] item >>= arrayOf)))
              ]
          )
      )
    | item <- fromMaybe [] (member "evidence" planned >>= arrayOf),
      any (\key -> maybe False isTruthy (member key item)) ["against", "plannedAgainst"]
    ]
  where
    firstPresent keys item = case [value | key <- keys, Just value <- [entryField key item]] of
      value : _ -> Just value
      [] -> Nothing
    -- JSON.stringify writes undefined in an array as null.
    get key value = fromMaybe JNull (member key value)
    wiring d =
      JArray
        ( [get "dependency" d, get "endpoint" d, get "kind" d]
            ++ [ JArray [get "kind" i, get "product" i, get "version" i, fromMaybe JNull (entryField "commit" i), fromMaybe JNull (entryField "digest" i)]
               | Just i <- [member "implementation" d],
                 isTruthy i
               ]
            ++ concat [[get "identity" s, get "version" s, get "conformance" s] | Just s <- [member "standIn" d], isTruthy s]
        )
