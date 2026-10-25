-- | A cached pass is superseded as soon as a real check starts. Otherwise a
-- failed fresh run could leave yesterday's pass available to the next run.
-- ref:DEC-content-identity
module Ci.Cache (CacheResult(..), cachedCheck) where

import Control.Monad (when)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory)
import System.IO.Error (catchIOError, isDoesNotExistError)

data CacheResult = CacheHit | Checked Bool deriving (Eq, Show)

cachedCheck :: Bool -> FilePath -> FilePath -> IO Bool -> IO CacheResult
cachedCheck fresh recorded logFile check = do
  hit <- if fresh then pure False else doesFileExist recorded
  if hit
    then copyFile recorded logFile >> pure CacheHit
    else do
      catchIOError (removeFile recorded) $ \error' ->
        if isDoesNotExistError error' then pure () else ioError error'
      passed <- check
      when passed $ do
        createDirectoryIfMissing True (takeDirectory recorded)
        copyFile logFile recorded
      pure (Checked passed)
