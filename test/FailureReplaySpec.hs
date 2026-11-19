{-# LANGUAGE LambdaCase #-}

-- | The failure database and replay batches of lawspec test, ported from
-- npm/test/replay.test.mjs and npm/test/failure-database.test.mjs when the
-- legacy CLI's replay.mjs and failure-database.mjs left the package
-- (0.36.0). Each example keeps the legacy test's case and expected values.
-- ref:DEC-haskell-application-port ref:DEC-s1j-shared-failures
module FailureReplaySpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.Command
import LawSpec.App.Json
import LawSpec.App.Main (pureCompiler)
import LawSpec.App.Test (failureDatabase, projectKey)
import LawSpec.App.TestResults
import LawSpec.Host.Fake
import Test.Hspec

law :: String -> Json
law name = JObject [("law", JString ("unit::law::" ++ name))]

lawName :: String -> String
lawName name = "unit::law::" ++ name

own :: Json -> Json
own seed = JObject [("seed", seed), ("failed", JString "2026-11-01T00:00:00.000Z"), ("cause", JString ownFailure)]

number :: Integer -> Json
number = JNumber . fromInteger

at :: String
at = "2026-11-12T00:00:00.000Z"

batches :: [Json] -> [(String, Json)] -> String -> Bool -> [(String, Bool, [Json])]
batches stale database seed replay =
  either error (map (\b -> (batchSeed b, batchReplay b, batchEntries b))) (planBatches stale database seed replay)

attempt :: String -> Integer -> [String] -> Json
attempt outcome seed statuses =
  JObject [("outcome", JString outcome), ("seed", number seed), ("tests", JArray [JObject [("status", JString s)] | s <- statuses])]

tests :: [String] -> [Json]
tests statuses = [JObject [("status", JString s)] | s <- statuses]

summary :: String -> Bool -> [String] -> [String] -> Json
summary seed replay ran notRun =
  JObject
    ( [("seed", JString seed), ("replay", JBool replay), ("ran", JArray (map (JString . lawName) ran))]
        ++ [("notRun", JArray (map (JString . lawName) notRun)) | not (null notRun)]
    )

-- | failureDatabase over the in-memory host, with writes below /r.
openDatabase :: String -> FilePath -> World -> (Either Abort (FilePath, FilePath, [(String, Json)]), World)
openDatabase language root =
  runFake (fst <$> runCommand (newSession fakeHost pureCompiler) (grantRead ["/r"] >> grantWrite ["/r"] >> failureDatabase "/r" language root))

-- | An open that must succeed.
opened :: String -> FilePath -> World -> ((FilePath, FilePath, [(String, Json)]), World)
opened language root world = case openDatabase language root world of
  (Right result, world') -> (result, world')
  (Left problem, _) -> error (show problem)

contents :: FilePath -> World -> Maybe String
contents path world = case M.lookup path (worldFiles world) of
  Just (FileNode bytes) -> Just (BC.unpack bytes)
  _ -> Nothing

spec :: Spec
spec = describe "lawspec test's failure replay" $ do
  let a = law "a"
      b = law "b"
      c = law "c"
      d = law "d"
  describe "batches" $ do
    it "replays only database laws, each batch with its recorded seed, before the fresh batch" $
      batches [a, b, c, d] [(lawName "b", own (number 7)), (lawName "d", own (JString "9")), (lawName "c", own (number 7))] "42" True
        `shouldBe` [("7", True, [b, c]), ("9", True, [d]), ("42", False, [a])]
    it "runs every law in one batch with an explicit seed, and ignores a database law outside the selection" $ do
      batches [a, b] [(lawName "b", own (number 7))] "5" False `shouldBe` [("5", False, [a, b])]
      batches [a] [(lawName "b", own (number 7))] "5" True `shouldBe` [("5", False, [a])]
      batches [] [(lawName "b", own (number 7))] "5" True `shouldBe` []
    it "replays a seed larger than a safe integer exactly and refuses a malformed one" $ do
      let big = "18446744073709551615"
      batches [a] [(lawName "a", own (JString big))] "1" True `shouldBe` [(big, True, [a])]
      let refused seed = case planBatches [a] [(lawName "a", JObject [("seed", seed)])] "1" True of
            Left message -> "no whole-number seed for unit::law::a" `isInfixOf` message
            Right _ -> False
      map refused [JNull, JString "x", number (-1), JNumber 1.5] `shouldBe` replicate 4 True
      isLeft (planBatches [a] [(lawName "a", JObject [])] "1" True) `shouldBe` True
  describe "progress" $ do
    it "stops neither the batch nor the run for a failed invocation that executed tests" $ do
      let (failing, failed, continueBatch) = afterInvocation startBatch False (tests ["passed", "failed"]) 2
      (failed, continueBatch, continueRun failing) `shouldBe` (True, True, True)
      -- A runner that exits 0 with a failed test in its report still failed.
      let (reported, reportedFailed, _) = afterInvocation startBatch True (tests ["failed"]) 1
      (reportedFailed, continueRun reported) `shouldBe` (True, True)
    it "ends the batch for a failed invocation that executed no law's test, and the run when the batch executed none" $ do
      let (unstarted, _, unstartedGoes) = afterInvocation startBatch False [] 0
      (unstartedGoes, continueRun unstarted) `shouldBe` (False, False)
      -- A test file that does not load is one failed test that belongs to no law.
      let (unloaded, _, unloadedGoes) = afterInvocation startBatch False (tests ["failed"]) 0
      (unloadedGoes, continueRun unloaded) `shouldBe` (False, False)
      -- An earlier invocation of the same batch executed tests: later batches run.
      let (first, firstFailed, _) = afterInvocation startBatch True (tests ["passed"]) 1
          (second, _, secondGoes) = afterInvocation first False [] 0
      (firstFailed, secondGoes, continueRun second) `shouldBe` (False, False, True)
    it "continues a passing batch, including one whose runner matched no test" $ do
      let (passing, failed, continueBatch) = afterInvocation startBatch True [] 0
      (failed, continueBatch, continueRun passing) `shouldBe` (False, True, True)
  describe "recording" $ do
    it "records only a law whose own tests failed" $
      recordFailures
        []
        [a, b, c, d]
        [lawName "d"]
        [ (lawName "a", attempt "failed" 11 ["failed"]),
          -- Its tests passed, but its native invocation failed because of a.
          (lawName "b", attempt "incomplete" 11 ["passed"]),
          (lawName "c", attempt "not-run" 11 []),
          (lawName "d", attempt "passed" 11 ["passed"])
        ]
        at
        `shouldBe` [(lawName "a", JObject [("seed", number 11), ("failed", JString at), ("cause", JString ownFailure)])]
    it "removes a recorded failure when its law passes and keeps its seed until then" $
      recordFailures
        [(lawName "a", own (number 7)), (lawName "b", own (number 8)), (lawName "c", own (number 9))]
        [a, b, c]
        [lawName "a"]
        [ (lawName "a", attempt "passed" 7 ["passed"]),
          -- Started, not completed: the earlier own failure is still the last one.
          (lawName "b", attempt "incomplete" 8 ["passed"]),
          (lawName "c", attempt "not-run" 9 [])
        ]
        at
        `shouldBe` [(lawName "b", own (number 8)), (lawName "c", own (number 9))]
    it "records the seed that failed now for a failure replayed with another seed" $
      lookup (lawName "a") (recordFailures [(lawName "a", own (number 7))] [a] [] [(lawName "a", attempt "failed" 99 ["failed"])] at)
        `shouldBe` Just (JObject [("seed", number 99), ("failed", JString at), ("cause", JString ownFailure)])
    it "keeps an entry of a law outside this run as it is" $ do
      let recorded = [(lawName "a", own (number 7)), (lawName "b", JObject [("seed", number 3), ("failed", JString "earlier")])]
      recordFailures recorded [] [] [] at `shouldBe` recorded
    it "replays an entry written by the old rule once, then marks or removes it" $ do
      -- Before 0.34 one failing invocation recorded all four laws with its seed.
      let old = JObject [("seed", number 5), ("failed", JString "2026-10-01T00:00:00.000Z")]
          legacy = [(lawName n, old) | n <- ["a", "b", "c", "d"]]
      batches [a, b, c, d] legacy "42" True `shouldBe` [("5", True, [a, b, c, d])]
      let recorded =
            recordFailures
              legacy
              [a, b, c, d]
              [lawName "d"]
              [ (lawName "a", attempt "failed" 5 ["failed"]),
                (lawName "b", attempt "incomplete" 5 ["passed"]),
                -- The tool could not start for c: it has not had its replay.
                (lawName "c", attempt "incomplete" 5 []),
                (lawName "d", attempt "passed" 5 ["passed"])
              ]
              at
      recorded `shouldBe` [(lawName "a", JObject [("seed", number 5), ("failed", JString at), ("cause", JString ownFailure)]), (lawName "c", old)]
      -- The next run replays the real failure alone; b runs with the fresh seed.
      batches [a, b] (take 1 recorded) "43" True `shouldBe` [("5", True, [a]), ("43", False, [b])]
  describe "summaries" $ do
    it "reports each batch's seed, the laws it ran and the laws never started" $ do
      let rows =
            batchSummaries
              [Batch "7" True [a], Batch "42" False [b, c]]
              [(lawName "a", JObject [("outcome", JString "failed")]), (lawName "b", JObject [("outcome", JString "passed")]), (lawName "c", JObject [("outcome", JString "not-run")])]
      rows `shouldBe` [summary "7" True ["a"] [], summary "42" False ["b"] ["c"]]
      ranText rows `shouldBe` "ran 2 law(s): 1 replayed with seed 7, 1 with seed 42"
    it "names the seed a single batch used, which may be a replayed one" $ do
      ranText [summary "7" True ["a"] []] `shouldBe` "ran 1 law(s) with seed 7"
      ranText [summary "7" True [] ["a"], summary "42" False ["b", "c"] []] `shouldBe` "ran 2 law(s) with seed 42"
      ranText [summary "42" False [] ["a"]] `shouldBe` "ran 0 law(s)"
  describe "the failure database" $ do
    it "keeps failure seeds per language and project root" $ do
      let world0 = withDirectory "/r" emptyWorld
          ((first, firstFile, firstDatabase), world1) = opened "erlang" "/r/first" world0
          ((second, _, _), world2) = opened "erlang" "/r/second" world1
          ((another, _, _), world3) = opened "elixir" "/r/first" world2
          world4 = withFile firstFile (BC.pack "{\"unit::law::check\": {\"seed\": 911}}") world3
          ((_, _, reread), world5) = opened "erlang" "/r/first" world4
          ((_, _, other), _) = opened "erlang" "/r/second" world5
      firstDatabase `shouldBe` []
      length (filter id [first /= second, second /= another, first /= another]) `shouldBe` 3
      first `shouldBe` "/r/.lawspec/failures/erlang/" ++ projectKey "/r/first"
      reread `shouldBe` [("unit::law::check", JObject [("seed", number 911)])]
      other `shouldBe` []
    it "copies an old database and its counterexamples once, without changing the originals" $ do
      let legacy = "/r/.lawspec/failures/rust/"
          inputs = [("inputs/law.json", "[1]"), ("hypothesis/key/example", "native example"), ("proptest-regressions.txt", "seed regression"), ("laws.json", "{\"law\":{\"seed\":42}}")]
          world0 = foldr (\(name, text) -> withFile (legacy ++ name) (BC.pack text)) (withDirectory "/r" emptyWorld) inputs
          ((first, firstFile, firstDatabase), world1) = opened "rust" "/r/first" world0
      firstDatabase `shouldBe` [("law", JObject [("seed", number 42)])]
      [contents (legacy ++ name) world1 | (name, _) <- inputs] `shouldBe` map (Just . snd) inputs
      [contents (first ++ "/" ++ name) world1 | (name, _) <- inputs, name /= "laws.json"] `shouldBe` [Just text | (name, text) <- inputs, name /= "laws.json"]
      -- Once copied, the project's own database is what is read.
      let world2 = (withFile firstFile (BC.pack "{}") world1) {worldFiles = M.filterWithKey (\path _ -> not ((first ++ "/inputs") `isPrefixOf` path)) (worldFiles (withFile firstFile (BC.pack "{}") world1))}
          ((_, _, emptied), world3) = opened "rust" "/r/first" world2
          ((second, _, secondDatabase), world4) = opened "rust" "/r/second" world3
      emptied `shouldBe` []
      contents (first ++ "/inputs/law.json") world3 `shouldBe` Nothing
      secondDatabase `shouldBe` [("law", JObject [("seed", number 42)])]
      contents (second ++ "/inputs/law.json") world4 `shouldBe` Just "[1]"
    it "fails on a malformed old or project database without discarding it" $ do
      let legacyFile = "/r/.lawspec/failures/python/laws.json"
          failsWith text = \case
            (Left (Aborted failure), _) -> text `isInfixOf` failureMessage failure
            _ -> False
          broken = openDatabase "python" "/r" (withFile legacyFile (BC.pack "broken json") (withDirectory "/r" emptyWorld))
      isLeft (fst broken) `shouldBe` True
      contents legacyFile (snd broken) `shouldBe` Just "broken json"
      failsWith "map of law identities" (openDatabase "python" "/r" (withFile legacyFile (BC.pack "[]") (withDirectory "/r" emptyWorld))) `shouldBe` True
      let ((_, scopedFile, _), world1) = opened "python" "/r" (withFile legacyFile (BC.pack "{}") (withDirectory "/r" emptyWorld))
          corrupted = openDatabase "python" "/r" (withFile scopedFile (BC.pack "null") world1)
      failsWith "map of law identities" corrupted `shouldBe` True
      contents scopedFile (snd corrupted) `shouldBe` Just "null"
