-- | The canonical-format check: canon (ref:canon) reads this repository through
-- canon.yaml, whose language profiles name grammars under .canon/grammars, so
-- the grammars and the binary always come from one canon checkout and are not
-- copied here. ref:DEC-canon-from-a-checkout canon.yaml reads the runtimes
-- through canon's dialects (ref:DEC-canon-dialect-profiles) and leaves
-- generated files alone (ref:DEC-generated-files-not-checked).
--
--   lawspec-dev canon [arguments]   run canon from the repository root;
--                                   no arguments means check
--   lawspec-dev tax <verb> [...]    run Rice's Tax (ref:rices-tax) from the
--                                   root: assess, pay [port], audit
--
-- CANON_HOME names the canon checkout, built with stack build; .canon is
-- linked to it. CANON names the binary when it is not that checkout's own.
-- Without a checkout the check is skipped with a message, so a machine
-- without canon still runs the rest of the complete check.
module Canon (canonCommand, taxCommand) where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import System.Directory (createDirectoryLink, doesDirectoryExist, doesFileExist, getSymbolicLinkTarget, removeDirectoryLink)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..), die, exitWith)
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

-- | Runs Rice's Tax over the repository, the review page through which the
-- owner vets canon's pending material ref:DEC-vet-with-rices-tax. RICESTAX_HOME
-- names a Rice's Tax checkout built with stack build, or RICESTAX its binary;
-- CANON_HOME names the canon checkout as for canon. Rice's Tax is built
-- against one canon version, so the two must be the same canon: it refuses a
-- repository whose canon.yaml names another, and this refuses a CANON_HOME
-- whose canon is not the one Rice's Tax was built with. pay serves the page
-- from the checkout's npm/page.
taxCommand :: [String] -> IO ()
taxCommand arguments = do
  home <- lookupEnv "RICESTAX_HOME"
  canonHome <- checkout
  case (home, canonHome) of
    (Nothing, _) -> die
      "Rice's Tax is not installed: set RICESTAX_HOME to a Rice's Tax checkout \
      \built with stack build (see docs/how-to/vet.md)."
    (_, Nothing) -> die
      "canon is not installed: set CANON_HOME to the canon checkout Rice's Tax \
      \is built against (see docs/how-to/vet.md)."
    (Just directory, Just canonDirectory) -> do
      link canonDirectory
      binary <- taxBinary directory
      canon <- canonBinary canonDirectory
      (_, canonVersion, _) <- readProcessWithExitCode canon ["version"] ""
      (_, taxCanon, _) <- readProcessWithExitCode binary ["canon", "version"] ""
      unless (canonVersion == taxCanon) $ die
        ("CANON_HOME is " ++ firstLine canonVersion ++ ", but Rice's Tax is built with "
          ++ firstLine taxCanon ++ "; point CANON_HOME at the canon its stack.yaml names.")
      code <- rawSystem binary (withPage directory arguments)
      unless (code == ExitSuccess) (exitWith code)
  where
    firstLine = takeWhile (/= '\n')
    withPage directory args = case args of
      ["pay"] -> ["pay", "8080", directory </> "npm/page"]
      ["pay", port] -> ["pay", port, directory </> "npm/page"]
      _ -> args

-- | RICESTAX, or the binary stack built in the Rice's Tax checkout.
taxBinary :: FilePath -> IO FilePath
taxBinary directory = do
  named <- lookupEnv "RICESTAX"
  case named of
    Just binary | not (null binary) -> pure binary
    _ -> do
      (code, root, _) <- readProcessWithExitCode "stack" ["--stack-yaml", directory </> "stack.yaml", "path", "--local-install-root"] ""
      let binary = takeWhile (/= '\n') root </> "bin" </> "ricestax"
      built <- if code == ExitSuccess then doesFileExist binary else pure False
      if built then pure binary else die ("no ricestax binary under " ++ directory ++ ": run stack build there")
