-- | Exercise the real pass-record lifecycle, including interrupted checks,
-- independently of CI's subprocess and scheduler machinery.
module Main where

import Ci.Cache
import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.IORef
import System.Directory
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

main :: IO ()
main = bracket temporary removePathForcibly $ \root -> do
  let recorded = root </> "passed"
      logFile = root </> "output"
  count <- newIORef (0 :: Int)
  let check result output = modifyIORef' count (+ 1) >> writeFile logFile output >> pure result
      expect message actual expected = unless (actual == expected) (fail (message ++ ": " ++ show actual))
  first <- cachedCheck False recorded logFile (check True "first pass")
  expect "initial execution" first (Checked True)
  hit <- cachedCheck False recorded logFile (fail "cached execution unexpectedly ran")
  expect "unchanged reuse" hit CacheHit
  failed <- cachedCheck True recorded logFile (check False "fresh failure")
  expect "fresh failure" failed (Checked False)
  exists <- doesFileExist recorded
  expect "failure removed previous pass" exists False
  again <- cachedCheck False recorded logFile (check False "normal failure")
  expect "known failure executes again" again (Checked False)
  recovered <- cachedCheck False recorded logFile (check True "new pass")
  expect "recovery executes" recovered (Checked True)
  cached <- cachedCheck False recorded logFile (fail "recovered pass was not cached")
  expect "recovered result reuse" cached CacheHit
  output <- readFile logFile
  expect "only the latest pass is replayed" output "new pass"
  attempts <- readIORef count
  expect "actual execution count" attempts 4
  interrupted <- try (cachedCheck True recorded logFile (ioError (userError "interrupted check"))) :: IO (Either IOException CacheResult)
  unless (either (const True) (const False) interrupted) (fail "interruption was concealed")
  remaining <- doesFileExist recorded
  expect "interruption also supersedes previous pass" remaining False
  putStrLn "CI pass, reuse, fresh failure, retry, recovery and interruption controls passed."
  where
    temporary = do
      parent <- getTemporaryDirectory
      (file, handle) <- openTempFile parent "lawspec-ci-cache-"
      hClose handle
      removeFile file
      createDirectory file
      pure file
