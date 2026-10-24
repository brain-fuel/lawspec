-- | The native test command for each target, shared by every acceptance suite.
module Toolchain (Toolchain(..), toolchain, Formatter(..), formatter, mutantArguments, compileFailure) where

import Data.Char (toLower, isSpace)
import Data.List (isInfixOf, isSuffixOf, sort, stripPrefix, dropWhileEnd)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory, removePathForcibly, withCurrentDirectory)
import System.IO (readFile')
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (callProcess, readProcess)
import Control.Monad (when)

data Toolchain = Toolchain
  { command :: FilePath
  , arguments :: [String]
  , prepare :: IO ()  -- run before every test invocation
  , report :: IO String  -- output kept outside the console, such as test reports
  }

-- | A target's canonical formatter in check mode, run on the generated
-- sources of a project: generated code must be a fixed point of it. The
-- version is pinned where the formatter is installed (ruff in
-- test/locks/python.txt, Go's release in test/locks/go/gofmt.txt), which is
-- part of the acceptance cache key.
-- ref:DEC-readable-output-default
data Formatter = Formatter
  { formatterName :: String
  , formatterCommand :: FilePath
  , formatterArguments :: FilePath -> [String]  -- given the directory to check
  , formatterExtensions :: [String]
  , formatterInputs :: [FilePath]  -- files outside the project that pin it
  }

formatter :: String -> IO (Maybe Formatter)
formatter target = do
  root <- getCurrentDirectory
  case target of
    "python" -> do
      python <- maybe (root </> ".integration/python/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      -- ruff format's default configuration, whatever a project's files say.
      pure (Just (Formatter "ruff format" python
        (\dir -> ["-m", "ruff", "format", "--check", "--diff", "--isolated", "--no-cache", dir]) [".py"]
        ["test/locks/python.txt"]))
    "prolog" -> do
      python <- maybe (root </> ".integration/prolog/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      -- SWI-Prolog's conventional layout for Prolog (the SWI version is in
      -- the prolog fingerprint) and ruff format for the Python host files.
      pure (Just (Formatter "SWI-Prolog portray_clause and ruff format" "sh"
        (\dir -> ["tools/prolog-formatted.sh", python, dir]) [".pl", ".py"]
        ["tools/prolog-formatted.sh", "tools/prolog-layout.pl", "test/locks/prolog.txt"]))
    -- gofmt comes with Go, so the Go release is the pin: the one named in
    -- test/locks/go/gofmt.txt, or the step fails before checking anything.
    -- gofmt -d exits non-zero when any file would change.
    "go" -> do
      let lock = root </> "test/locks/go/gofmt.txt"
          script = unlines
            [ "want=$(tr -d '[:space:]' < \"$1\")"
            , "have=$(go env GOVERSION) || exit 2"
            , "if [ \"$have\" != \"$want\" ]; then echo \"gofmt is pinned to $want; found $have\"; exit 2; fi"
            , "exec \"$(go env GOROOT)/bin/gofmt\" -d \"$2\"" ]
      pure (Just (Formatter "gofmt" "sh" (\dir -> ["-c", script, "gofmt-check", lock, dir]) [".go"]
        ["test/locks/go/gofmt.txt"]))
    _ -> pure Nothing

-- | Offline builds use existing dependency caches (LAWSPEC_OFFLINE=1).
toolchain :: FilePath -> String -> IO Toolchain
toolchain project target = do
  offline <- (== Just "1") <$> lookupEnv "LAWSPEC_OFFLINE"
  release <- (== Just "1") <$> lookupEnv "LAWSPEC_RUST_RELEASE"
  root <- getCurrentDirectory
  let flag f = [f | offline]
  case target of
    "rust" -> pure (plain "cargo" ("test" : flag "--offline" ++ ["--release" | release]))
    "java" -> pure (plain "mvn" (flag "-o" ++ ["-q", "test"]))
    "python" -> do
      python <- maybe (root </> ".integration/python/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      -- Same-size rewrites within one second can reuse Python's timestamp-based
      -- bytecode cache, so the adapter's cache is always removed first.
      pure (Toolchain python ["-B", "-m", "pytest", "-q"]
        (removePathForcibly (project </> "src/example/__pycache__")) (pure ""))
    "prolog" -> do
      python <- maybe (root </> ".integration/prolog/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      pure (Toolchain python ["-B", "lawspec_test.py"]
        (removePathForcibly (project </> "src/example/__pycache__")) (pure ""))
    "javascript" -> do
      tests <- sort . filter (".test.mjs" `isSuffixOf`) <$> listDirectory (project </> "test")
      pure (plain "node" ("--test" : map ("test" </>) tests))
    "typescript" -> pure (plain "npm" ["test"])
    "go" -> pure (plain "go" ["test", "./..."])
    "haskell" -> pure (plain "stack" ["--no-terminal", "test"])
    -- Rebar's source timestamps have one-second resolution. A fast mutant
    -- rewrite can otherwise run the preceding adapter's BEAM file. Clear the
    -- project's compiled modules; dependency caches remain reusable.
    "erlang" -> pure (Toolchain "rebar3" ["eunit"]
      (mapM_ (removePathForcibly . (project </>))
        ["_build/test/lib/lawspec_example/ebin", "_build/test/lib/lawspec_example/test"])
      (pure ""))
    -- Mix also misses equal-size source mutations within one timestamp tick.
    -- Remove only the application's BEAM files and compilation manifests.
    "elixir" -> pure (Toolchain "mix" ["test"]
      (mapM_ (removePathForcibly . (project </>))
        ["_build/test/lib/lawspec_example/ebin", "_build/test/lib/lawspec_example/.mix"])
      (pure ""))
    "gleam" -> pure (Toolchain "gleam" ["test"] (prepareCrypto project) (pure ""))
    -- The runner compiles the Java model when it changed, then runs every
    -- test namespace and writes JUnit XML to target/test-results.
    "clojure" -> pure (Toolchain "clojure" ["-M:test"] (pure ()) (xmlReports (project </> "target/test-results")))
    _ | target `elem` ["kotlin", "groovy"] -> do
      let local = root </> ".tools/gradle-9.3.0/bin/gradle"
      gradle <- (\exists -> if exists then local else "gradle") <$> doesFileExist local
      -- Gradle prints failing test names only; assertion messages are in the XML reports.
      pure (Toolchain gradle ["test", "--console=plain"] (pure ()) (xmlReports (project </> "build/test-results/test")))
    -- dotnet test builds the solution incrementally (MSBuild compares file
    -- contents' timestamps at full resolution) and runs it on
    -- Microsoft.Testing.Platform, as global.json selects.
    -- Scala CLI compiles incrementally on its Bloop server.
    "scala" -> pure (plain "scala" (["test", "."] ++ flag "--power" ++ flag "--offline"))
    _ | target `elem` ["fsharp", "csharp"] ->
        pure (Toolchain "dotnet" ("test" : ["--no-restore" | offline])
          (when offline (restoreDotNet project)) (pure ""))
    -- swift test builds incrementally (SwiftPM compares file contents'
    -- timestamps at full resolution) and runs the Swift Testing tests.
    "swift" -> pure (plain "swift" ["test"])
    _ -> ioError (userError ("unknown target: " ++ target))
  where plain c a = Toolchain c a (pure ()) (pure "")

-- Fresh acceptance projects have no generated NuGet imports yet. Restore
-- those from the installed package cache before asking the SDK to select its
-- test runner. A local source and disabled audit keep offline runs offline;
-- missing cached packages fail the restore instead of selecting another runner.
restoreDotNet :: FilePath -> IO ()
restoreDotNet project = do
  output <- readProcess "dotnet" ["nuget", "locals", "global-packages", "--list", "--force-english-output"] ""
  cache <- case lines output of
    [line] | Just path <- stripPrefix "global-packages: " line -> pure (dropWhileEnd isSpace path)
    _ -> ioError (userError "cannot locate the dotnet global package cache")
  withCurrentDirectory project $
    callProcess "dotnet" ["restore", "--source", cache, "-p:NuGetAudit=false", "--verbosity", "quiet"]

-- Gleam has no project precompile hook. Its native bridge is built explicitly,
-- before Gleam copies priv into the application and production shipment.
prepareCrypto :: FilePath -> IO ()
prepareCrypto project = do
  let script = project </> "lawspec_crypto_build.escript"
  present <- doesFileExist script
  when present (callProcess "escript" [script, project])

xmlReports :: FilePath -> IO String
xmlReports dir = do
  exists <- doesDirectoryExist dir
  names <- if exists then sort . filter (".xml" `isSuffixOf`) <$> listDirectory dir else pure []
  concat <$> mapM (readFile' . (dir </>)) names

-- | Stop at the first counterexample: a mutant only has to fail once.
mutantArguments :: String -> [String] -> [String]
mutantArguments "python" args = args ++ ["-x"]
mutantArguments _ args = args

-- | A mutant must fail its laws, not the build. These markers identify build and
-- type-checking failures in each toolchain's output. ANSI escape sequences are
-- stripped first, since a toolchain that colours its errors (Gleam under
-- FORCE_COLOR) would otherwise split a marker such as "error: Type mismatch".
compileFailure :: String -> Bool
compileFailure output = any rebarFailure (lines lowered) || any ((`isInfixOf` lowered) . map toLower)
  [ "error[E", "could not compile", "COMPILATION ERROR", "compileKotlin FAILED"
  , "compileTestKotlin FAILED", "compileGroovy FAILED", "compileTestGroovy FAILED", "Syntax error compiling", "Syntax error reading source", "Syntax error macroexpanding", "SyntaxError", "[build failed]", "parse error on input"
  , "not in scope", "error TS", "couldn't match expected type"
  , "syntax error before:", "undefined function", "** (CompileError)"
  , "error: Type mismatch", "error: Unknown variable", "error: Unknown type"
  , "error: Unknown module", "error: Unknown value", ": error FS", ": error CS"
  , "error compiling project" ]
    || any swiftFailure (lines lowered)
  where
    lowered = map toLower (stripAnsi output)
    rebarFailure line = all (`isInfixOf` line) ["===>", "compiling ", " failed"]
    -- Swift's compiler: path.swift:line:column: error: ...
    swiftFailure line = ".swift:" `isInfixOf` line && ": error: " `isInfixOf` line

-- | Drop ANSI escape sequences: control sequences (ESC, a bracket, parameters
-- and a final byte from 0x40 to 0x7E) and two-byte escapes (ESC and one more).
stripAnsi :: String -> String
stripAnsi ('\ESC' : '[' : rest) = stripAnsi (drop 1 (dropWhile (\c -> c < '@' || c > '~') rest))
stripAnsi ('\ESC' : _ : rest) = stripAnsi rest
stripAnsi (c : rest) = c : stripAnsi rest
stripAnsi [] = []
