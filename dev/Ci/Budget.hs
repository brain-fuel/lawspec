-- | What concurrent runs of lawspec-dev ci share on one machine: a budget
-- of jobs, and named locks for the work that must not overlap between runs.
--
-- Both are advisory locks on files under the shared development cache
-- (flock, through GHC.IO.Handle.Lock). The operating system releases such a
-- lock when its holder exits, however it exits, so a crashed or killed run
-- never leaves a slot or a lock taken, and no run has to judge whether
-- another is still alive.
--
-- The budget is a directory of slot files, slot-0 to slot-(n-1). A step
-- holds one slot while it runs, so however many runs there are, at most n
-- steps run at once. A step that must have the machine to itself holds every
-- slot, taken in order so that two such steps cannot wait on each other.
-- Runs configured with different sizes still share the slots they have in
-- common, so the larger size bounds the total.
--
-- A handle is opened for writing, and the runtime allows one writer of a
-- file in a process, so threads of one run exclude each other as well.
module Ci.Budget (Budget, newBudget, budgetSize, withSlot, withEverySlot, withMachineLock, tryHold) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, onException, throwIO, try)
import GHC.IO.Handle.Lock (LockMode(..), hTryLock, hUnlock)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (Handle, IOMode(..), hClose, openFile)
import System.IO.Error (isAlreadyInUseError)

data Budget = Budget FilePath Int

-- | The budget of the given size in a shared cache directory.
newBudget :: FilePath -> Int -> IO Budget
newBudget cache size = do
  let directory = cache </> "jobs"
  createDirectoryIfMissing True directory
  pure (Budget directory (max 1 size))

budgetSize :: Budget -> Int
budgetSize (Budget _ size) = size

slot :: Budget -> Int -> FilePath
slot (Budget directory _) index = directory </> ("slot-" ++ show index)

-- | Hold the file's lock if nobody does: no other process, and no other
-- thread of this one.
tryHold :: FilePath -> IO (Maybe Handle)
tryHold path = do
  opened <- try (openFile path ReadWriteMode)
  case opened of
    Left busy
      | isAlreadyInUseError busy -> pure Nothing
      | otherwise -> throwIO busy
    Right handle -> do
      free <- hTryLock handle ExclusiveLock `onException` hClose handle
      if free then pure (Just handle) else hClose handle >> pure Nothing

release :: Handle -> IO ()
release handle = hUnlock handle >> hClose handle

-- The waits poll: a blocked flock could not be interrupted by Ctrl-C.
pause :: IO ()
pause = threadDelay 200000

hold :: FilePath -> IO Handle
hold path = tryHold path >>= maybe (pause >> hold path) pure

-- | Run the action holding one of the machine's job slots.
withSlot :: Budget -> IO a -> IO a
withSlot budget = bracket (search 0) release . const
  where
    search index
      | index >= budgetSize budget = pause >> search 0
      | otherwise = tryHold (slot budget index) >>= maybe (search (index + 1)) pure

-- | Run the action holding every job slot: nothing else runs beside it.
withEverySlot :: Budget -> IO a -> IO a
withEverySlot budget = bracket (go [] [0 .. budgetSize budget - 1]) (mapM_ release) . const
  where
    go held [] = pure held
    go held (index : rest) = do
      handle <- hold (slot budget index) `onException` mapM_ release held
      go (handle : held) rest

-- | Run the action holding a named machine-wide lock.
withMachineLock :: FilePath -> String -> IO a -> IO a
withMachineLock cache name = bracket acquire release . const
  where
    acquire = do
      let directory = cache </> "locks"
      createDirectoryIfMissing True directory
      hold (directory </> (name ++ ".lock"))
