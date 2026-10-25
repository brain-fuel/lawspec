-- | The worker pool behind lawspec-dev ci --jobs (dev/scheduler/Scheduler.hs).
module SchedulerSpec (test_parallelStepsNeverShareWhatTheyClaim) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Exception (ErrorCall(..), throwIO, try)
import Data.List (isPrefixOf, sort)
import qualified Data.Set as S
import Test.Hspec
import Scheduler

data Event = Start String | End String deriving (Eq, Show)

task :: String -> [String] -> [Claim] -> Task ()
task name follows claims = Task name follows claims ()

-- | Run tasks with the given jobs; each sleeps briefly and passes unless its
-- name is in the failing list. Gives the results and the events in order.
run :: Int -> Bool -> [String] -> [Task ()] -> IO ([(String, Bool)], [Event])
run jobs failFast failing tasks = do
  events <- newMVar []
  let note e = modifyMVar_ events (pure . (e :))
      body t = do
        note (Start (taskName t))
        threadDelay 3000
        note (End (taskName t))
        pure (taskName t `notElem` failing)
  results <- schedule jobs failFast tasks body (const (pure ())) (\_ _ -> pure ())
  (,) results . reverse <$> readMVar events

-- | The names running together at each point of the run.
overlaps :: [Event] -> [[String]]
overlaps = go []
  where
    go _ [] = []
    go current (Start n : rest) = let now = n : current in sort now : go now rest
    go current (End n : rest) = go (filter (/= n) current) rest

startsAfterEnd :: [Event] -> String -> String -> Bool
startsAfterEnd events first second = case (break (== End first) events, break (== Start second) events) of
  ((untilEnd, _ : _), (untilStart, _ : _)) -> length untilEnd < length untilStart
  _ -> False

-- | The complete check runs its steps in parallel only where they cannot
-- interfere, so a parallel run gives the results a sequential one would: a
-- step starts after those it follows have finished, never beside a step that
-- holds what it claims, and never beyond the job limit, and one job keeps the
-- sequential order exactly. ref:REQ-parallel-ci ref:DEC-parallel-ci
test_parallelStepsNeverShareWhatTheyClaim :: Spec
test_parallelStepsNeverShareWhatTheyClaim = describe "the CI worker pool" $ do
  describe "choosing what may start" $ do
    let known = S.fromList ["a", "b", "c", "d"]
    it "starts the earliest ready tasks, up to the free slots" $
      map taskName (startable 2 known S.empty [] [task "a" [] [], task "b" [] [], task "c" [] []]) `shouldBe` ["a", "b"]
    it "waits for the tasks a task follows, ignoring names not in the run" $ do
      map taskName (startable 4 known S.empty [] [task "a" [] [], task "b" ["a"] [], task "c" ["elsewhere"] []]) `shouldBe` ["a", "c"]
      map taskName (startable 4 known (S.fromList ["a"]) [] [task "b" ["a"] []]) `shouldBe` ["b"]
    it "lets shared claims run together and an exclusive claim run alone" $ do
      map taskName (startable 4 known S.empty [[Shared "env"]] [task "a" [] [Shared "env"], task "b" [] [Exclusive "env"]]) `shouldBe` ["a"]
      map taskName (startable 4 known S.empty [[Exclusive "env"]] [task "a" [] [Shared "env"], task "c" [] [Shared "other"]]) `shouldBe` ["c"]
    it "bounds a counted claim" $
      map taskName (startable 4 known S.empty [[Counted "timing" 2]] [task "a" [] [Counted "timing" 2], task "b" [] [Counted "timing" 2]]) `shouldBe` ["a"]
    it "holds back later sharers behind a waiting exclusive claim" $
      map taskName (startable 4 known S.empty [[Shared "env"]] [task "a" [] [Exclusive "env"], task "b" [] [Shared "env"], task "c" [] []]) `shouldBe` ["c"]
  describe "running" $ do
    let chain = [task "build" [] [Exclusive "stack"], task "x" ["build"] [Shared "stack", Exclusive "project:x"],
                 task "y" ["build"] [Shared "stack", Exclusive "project:x"], task "z" ["build"] [Shared "stack"],
                 task "w" [] [], task "v" [] []]
    it "rejects duplicate identities before starting any work" $ do
      ran <- newMVar False
      outcome <- try (schedule 2 False [task "same" [] [], task "same" [] []]
        (\_ -> modifyMVar_ ran (const (pure True)) >> pure True)
        (const (pure ())) (\_ _ -> pure ()))
      case outcome of
        Left e -> show (e :: IOError) `shouldSatisfy`
          ("user error (lawspec-dev ci: duplicate step names: same" `isPrefixOf`)
        Right _ -> expectationFailure "duplicate task identities ran"
      readMVar ran `shouldReturn` False
    it "keeps the sequential order with one job" $ do
      (results, events) <- run 1 False [] chain
      map fst results `shouldBe` map taskName chain
      events `shouldBe` concat [[Start (taskName t), End (taskName t)] | t <- chain]
    it "honors later-listed bootstrap prerequisites with one job" $ do
      let bootstraps = ["typescript-bootstrap", "javascript-bootstrap", "python-bootstrap"]
          checks = task "npm-tests" bootstraps [] : [task name [] [] | name <- bootstraps]
      (results, _) <- run 1 False [] checks
      map fst results `shouldBe` bootstraps ++ ["npm-tests"]
    it "never runs more than the jobs at once, and does run tasks together" $ do
      (results, events) <- run 3 False [] (chain ++ [task ("n" ++ show i) [] [] | i <- [1 .. 8 :: Int]])
      length results `shouldBe` 14
      maximum (map length (overlaps events)) `shouldBe` 3
    it "starts a task only after those it follows, and never beside a conflicting claim" $ do
      (_, events) <- run 4 False [] chain
      mapM_ (\n -> startsAfterEnd events "build" n `shouldBe` True) ["x", "y", "z"]
      overlaps events `shouldSatisfy` all (\names -> not ("x" `elem` names && "y" `elem` names))
      overlaps events `shouldSatisfy` all (\names -> not ("build" `elem` names && any (`elem` names) ["x", "y", "z"]))
    it "runs a task after a failed one it follows, as the sequential run does" $ do
      (results, _) <- run 4 False ["build"] chain
      lookup "build" results `shouldBe` Just False
      map fst results `shouldSatisfy` (\names -> all (`elem` names) ["x", "y", "z"])
    it "starts nothing new after a failure under fail-fast" $ do
      (results, _) <- run 1 True ["x"] chain
      map fst results `shouldBe` ["build", "x"]
    it "counts an exception as a failure" $ do
      results <- schedule 2 False [task "boom" [] [], task "fine" [] []]
        (\t -> if taskName t == "boom" then throwIO (ErrorCall "boom") else pure True)
        (const (pure ())) (\_ _ -> pure ())
      sort results `shouldBe` [("boom", False), ("fine", True)]
    it "reports a plan that can never progress" $ do
      outcome <- try (run 2 False [] [task "a" ["b"] [], task "b" ["a"] []])
      case outcome of
        Left e -> show (e :: IOError) `shouldSatisfy` ("user error (lawspec-dev ci: these steps can never start" `isPrefixOf`)
        Right _ -> expectationFailure "a dependency cycle ran"
