-- | The worker pool behind lawspec-dev ci --jobs N. Tasks run at most N at a
-- time; a task starts once every task it comes after has finished (passed or
-- failed, as the sequential run continues past a failure) and its claims are
-- compatible with those of the running tasks:
--
--   Shared r      any number at once, never beside Exclusive r
--   Exclusive r   alone on r
--   Counted r k   at most k at once
--
-- Among startable tasks the earliest in the list goes first, so with one job
-- and dependencies that only name earlier tasks the order is exactly the
-- list's. A task that is ready but blocked from claiming r exclusively
-- reserves r: later tasks that would claim r wait behind it, so a stream of
-- shared claims cannot starve an exclusive one.
--
-- This module knows nothing of processes; dev/Ci.hs declares the steps.
module Scheduler (Claim(..), Task(..), startable, schedule) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Claim = Shared String | Exclusive String | Counted String Int
  deriving (Eq, Show)

data Task a = Task
  { taskName :: String
  , taskAfter :: [String]  -- names of tasks that must finish first
  , taskClaims :: [Claim]
  , taskItem :: a }

resource :: Claim -> String
resource (Shared r) = r
resource (Exclusive r) = r
resource (Counted r _) = r

-- | The tasks that may start now, in list order: at most the free slots,
-- among pending tasks whose predecessors (those present in the run) have
-- finished, given the claims of the running tasks.
startable :: Int -> S.Set String -> S.Set String -> [[Claim]] -> [Task a] -> [Task a]
startable free known finished running = go free (concat running) S.empty
  where
    go slots held reserved (t : rest)
      | slots <= 0 = []
      | not ready = go slots held reserved rest
      | fits && not (any ((`S.member` reserved) . resource) (taskClaims t)) =
          t : go (slots - 1) (taskClaims t ++ held) reserved rest
      | otherwise = go slots held (S.union reserved (S.fromList [r | Exclusive r <- taskClaims t])) rest
      where
        ready = all (\n -> n `S.member` finished || not (n `S.member` known)) (taskAfter t)
        fits = all (compatible held) (taskClaims t)
    go _ _ _ [] = []

compatible :: [Claim] -> Claim -> Bool
compatible held claim = case claim of
  Shared r -> null [() | Exclusive r' <- held, r' == r]
  Exclusive r -> null [() | c <- held, resource c == r]
  Counted r k -> null [() | Exclusive r' <- held, r' == r] && length [() | Counted r' _ <- held, r' == r] < k

-- | Run the tasks with at most the given number at once, calling the runner
-- for each in a thread of its own (an exception counts as a failure) and
-- the callbacks as each starts and finishes (from the calling thread, in
-- that order). With failFast, nothing new starts after a failure, and the
-- running tasks finish. The result lists every task that ran, in the order
-- they finished. A plan that can never progress (a dependency cycle, or a
-- claim no task can satisfy) is an error.
schedule :: Int -> Bool -> [Task a] -> (Task a -> IO Bool)
         -> (Task a -> IO ()) -> (Task a -> Bool -> IO ()) -> IO [(String, Bool)]
schedule jobs failFast tasks run started finished = do
  done <- newChan
  let known = S.fromList (map taskName tasks)
      launch t = do
        started t
        _ <- forkIO $ do
          outcome <- try (run t) :: IO (Either SomeException Bool)
          writeChan done (taskName t, either (const False) id outcome)
        pure ()
      loop pending running finishedNames results stopped = do
        let starts = if stopped then [] else
              startable (max 1 jobs - M.size running) known finishedNames (map taskClaims (M.elems running)) pending
            startedNames = S.fromList (map taskName starts)
            running' = M.union running (M.fromList [(taskName t, t) | t <- starts])
            pending' = filter (not . (`S.member` startedNames) . taskName) pending
        forM_ starts launch
        if M.null running'
          then do
            unless (stopped || null pending') $
              ioError (userError ("lawspec-dev ci: these steps can never start: " ++ unwords (map taskName pending')))
            pure (reverse results)
          else do
            (name, ok) <- readChan done
            let t = running' M.! name
            finished t ok
            loop pending' (M.delete name running') (S.insert name finishedNames)
              ((name, ok) : results) (stopped || (failFast && not ok))
  loop tasks M.empty S.empty [] False
