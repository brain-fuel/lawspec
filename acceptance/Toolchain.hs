-- | The native test command for each target, shared by every acceptance suite.
module Toolchain (Toolchain(..), toolchain, mutantArguments, compileFailure) where

import Data.Char (toLower)
import Data.List (isInfixOf, isSuffixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory, removePathForcibly)
import System.IO (readFile')
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (callProcess)
import Control.Monad (when)

data Toolchain = Toolchain
  { command :: FilePath
  , arguments :: [String]
  , prepare :: IO ()  -- run before every test invocation
  , report :: IO String  -- output kept outside the console, such as test reports
  }

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
    "kotlin" -> do
      let local = root </> ".tools/gradle-9.3.0/bin/gradle"
      gradle <- (\exists -> if exists then local else "gradle") <$> doesFileExist local
      -- Gradle prints failing test names only; assertion messages are in the XML reports.
      pure (Toolchain gradle ["test", "--console=plain"] (pure ()) (xmlReports (project </> "build/test-results/test")))
    _ -> ioError (userError ("unknown target: " ++ target))
  where plain c a = Toolchain c a (pure ()) (pure "")

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
-- type-checking failures in each toolchain's output.
compileFailure :: String -> Bool
compileFailure output = any rebarFailure (lines lowered) || any ((`isInfixOf` lowered) . map toLower)
  [ "error[E", "could not compile", "COMPILATION ERROR", "compileKotlin FAILED"
  , "compileTestKotlin FAILED", "SyntaxError", "[build failed]", "parse error on input"
  , "not in scope", "error TS", "couldn't match expected type"
  , "syntax error before:", "undefined function", "** (CompileError)"
  , "error: Type mismatch", "error: Unknown variable", "error: Unknown type"
  , "error: Unknown module", "error: Unknown value" ]
  where
    lowered = map toLower output
    rebarFailure line = all (`isInfixOf` line) ["===>", "compiling ", " failed"]
