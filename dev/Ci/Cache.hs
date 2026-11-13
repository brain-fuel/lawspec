-- | A cached pass is superseded as soon as a real check starts. Otherwise a
-- failed fresh run could leave yesterday's pass available to the next run.
-- ref:DEC-content-identity
--
-- Records live in a directory every worktree on the machine shares
-- (LAWSPEC_DEV_CACHE, by default ~/.cache/lawspec-dev), so concurrent runs
-- read and write the same store. A record is therefore written beside its
-- final name and renamed into place: a reader sees a whole record or none.
module Ci.Cache (CacheResult(..), cachedCheck, sharedCache, recordAtomically) where

import Control.Exception (onException)
import Control.Monad (when)
import System.Directory (copyFile, createDirectoryIfMissing, getHomeDirectory, makeAbsolute, removeFile, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose, openTempFile)
import System.IO.Error (catchIOError, isDoesNotExistError)

data CacheResult = CacheHit | Checked Bool deriving (Eq, Show)

-- | The machine's shared development cache: recorded passes, the npm and Go
-- caches of the integration tools, and the files that coordinate concurrent
-- runs. acceptance/Cache.hs resolves the same directory the same way.
sharedCache :: IO FilePath
sharedCache = do
  configured <- lookupEnv "LAWSPEC_DEV_CACHE"
  case configured of
    Just directory | not (null directory) -> makeAbsolute directory
    _ -> (</> ".cache/lawspec-dev") <$> getHomeDirectory

-- | Fill a temporary sibling of the record, then rename it into place.
recordAtomically :: FilePath -> (FilePath -> IO ()) -> IO ()
recordAtomically recorded fill = do
  let directory = takeDirectory recorded
  createDirectoryIfMissing True directory
  (temporary, handle) <- openTempFile directory (takeFileName recorded ++ ".tmp")
  hClose handle
  (fill temporary >> renameFile temporary recorded) `onException` forget temporary

forget :: FilePath -> IO ()
forget path = catchIOError (removeFile path) $ \error' ->
  if isDoesNotExistError error' then pure () else ioError error'

cachedCheck :: Bool -> FilePath -> FilePath -> IO Bool -> IO CacheResult
cachedCheck fresh recorded logFile check = do
  hit <- if fresh then pure False else replay
  if hit
    then pure CacheHit
    else do
      forget recorded
      passed <- check
      when passed (recordAtomically recorded (copyFile logFile))
      pure (Checked passed)
  where
    -- Another run may supersede the record between a test for it and its
    -- use, so the replay itself decides whether there was one.
    replay = catchIOError (copyFile recorded logFile >> pure True) $ \error' ->
      if isDoesNotExistError error' then pure False else ioError error'
