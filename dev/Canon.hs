-- | The canonical-format check: canon (ref:canon) reads this repository through
-- canon.yaml, whose language profiles name grammars under .canon/grammars, so
-- the grammars and the binary always come from one canon checkout and are not
-- copied here. ref:DEC-canon-from-a-checkout
--
--   lawspec-dev canon [arguments]   run canon from the repository root;
--                                   no arguments means check
--
-- CANON_HOME names the canon checkout, built with stack build; .canon is
-- linked to it. CANON names the binary when it is not that checkout's own.
-- Without a checkout the check is skipped with a message, so a machine
-- without canon still runs the rest of the complete check.
module Canon (canonCommand) where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import System.Directory (createDirectoryLink, doesDirectoryExist, doesFileExist, getSymbolicLinkTarget, removeDirectoryLink)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..), exitWith)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode, rawSystem)

-- | Links .canon to the checkout and runs canon with the arguments.
canonCommand :: [String] -> IO ()
canonCommand arguments = do
  home <- checkout
  case home of
    Nothing -> putStrLn
      "canon is not installed: set CANON_HOME to a canon checkout built with \
      \stack build (see docs/how-to/contribute.md). Skipping the canonical-format check."
    Just directory -> do
      link directory
      binary <- canonBinary directory
      code <- rawSystem binary (if null arguments then ["check"] else arguments)
      unless (code == ExitSuccess) (exitWith code)

-- | CANON_HOME, or the checkout .canon already points at.
checkout :: IO (Maybe FilePath)
checkout = do
  named <- lookupEnv "CANON_HOME"
  linked <- linkTarget
  case [d | Just d <- [named, linked], not (null d)] of
    directory : _ -> do
      ok <- doesDirectoryExist (directory </> "grammars")
      pure (if ok then Just directory else Nothing)
    [] -> pure Nothing

-- | Where .canon points, if it is a link.
linkTarget :: IO (Maybe FilePath)
linkTarget = do
  result <- try (getSymbolicLinkTarget ".canon") :: IO (Either IOException FilePath)
  pure (either (const Nothing) Just result)

-- | Points .canon at the checkout, replacing a link to another one.
link :: FilePath -> IO ()
link directory = do
  current <- linkTarget
  when (current /= Just directory) $ do
    when (current /= Nothing) (removeDirectoryLink ".canon")
    createDirectoryLink directory ".canon"

-- | CANON, or the binary stack built in the checkout.
canonBinary :: FilePath -> IO FilePath
canonBinary directory = do
  named <- lookupEnv "CANON"
  case named of
    Just binary | not (null binary) -> pure binary
    _ -> do
      (code, root, _) <- readProcessWithExitCode "stack" ["--stack-yaml", directory </> "stack.yaml", "path", "--local-install-root"] ""
      let binary = takeWhile (/= '\n') root </> "bin" </> "canon"
      built <- if code == ExitSuccess then doesFileExist binary else pure False
      pure (if built then binary else "canon")
