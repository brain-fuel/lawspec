-- The complete LawSpec check, run locally from the repository root:
--
--   lawspec-dev ci                       everything, all eight targets
--   lawspec-dev ci --target rust --target go
--   lawspec-dev ci --core                compiler, npm and editor checks only
--   lawspec-dev ci --fail-fast
--   lawspec-dev ci --rust-toolchains 1.85.0,stable --rust-targets i686-unknown-linux-gnu
--
-- Each step's output goes to .artifacts/ci/<step>.log; the console shows one
-- line per step and a summary. Every step runs even after a failure unless
-- --fail-fast is given, and the exit status is non-zero if any step failed.
module Ci (ci) where

import Control.Monad (unless, when)
import Data.Char (isAlphaNum)
import Data.IORef
import Data.List (intercalate, isPrefixOf)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, getCurrentDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..), exitFailure, exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.Process (CreateProcess(..), proc, readCreateProcessWithExitCode)
import Text.Printf (printf)

data Options = Options
  { targets :: [String], coreOnly :: Bool, failFast :: Bool
  , rustToolchains :: [String], rustTargets :: [String] }

allTargets :: [String]
allTargets = ["java", "python", "javascript", "typescript", "go", "haskell", "kotlin", "rust"]

-- A step is a named command with extra environment, run from the root.
data Step = Step String [(String, String)] [String]

stepName :: Step -> String
stepName (Step name _ _) = name

ci :: [String] -> IO ()
ci args = do
  options <- either (\message -> putStrLn message >> exitFailure) pure (parse args)
  createDirectoryIfMissing True logs
  failures <- newIORef []
  let run current = do
        stop <- if failFast options then not . null <$> readIORef failures else pure False
        unless stop $ do
          ok <- runStep current
          unless ok (modifyIORef failures (stepName current :))
  mapM_ run coreSteps
  editor <- doesDirectoryExist "editors/vscode/node_modules"
  mapM_ run ([step "editor-install" ["npm", "install", "--prefix", "editors/vscode", "--ignore-scripts", "--no-audit", "--no-fund"] | not editor]
    ++ [step "editor-grammar" ["npm", "test", "--prefix", "editors/vscode"]])
  unless (coreOnly options) $ do
    mapM_ run [step "build-acceptance" ["stack", "--no-terminal", "build", "lawspec:exe:lawspec-acceptance"]]
    mapM_ (mapM_ run . targetSteps) (targets options)
    mapM_ run (rustRuntimeSteps options)
  failed <- reverse <$> readIORef failures
  putStrLn ""
  if null failed
    then putStrLn "All checks passed."
    else do
      putStrLn ("Failed: " ++ intercalate ", " failed)
      putStrLn ("Logs: " ++ logs)
      exitWith (ExitFailure 1)

logs :: FilePath
logs = ".artifacts/ci"

localGradle :: FilePath
localGradle = ".tools/gradle-9.3.0/bin"

step :: String -> [String] -> Step
step name = Step name []

coreSteps :: [Step]
coreSteps =
  [ step "integrity" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "integrity"]
  , step "boundaries" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "boundaries"]
  , step "generated" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "generate", "--check"]
  , step "version" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "version", "--check"]
  , step "compiler-tests" ["stack", "--no-terminal", "test"]
  , step "npm-tests" ["sh", "-c", "node --test npm/test/*.test.mjs"]
  , step "parity" ["node", "tools/parity.mjs"]
  , step "package-smoke" ["node", "tools/package-smoke.mjs"]
  , step "docs" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "docs", "--check"] ]

-- The profiles match the acceptance matrix: suites run with mutants in the
-- default profile, and with the 32-bit (and compact) profiles as well.
targetSteps :: String -> [Step]
targetSteps target =
  [ step (target ++ "-bootstrap") ["node", "tools/bootstrap-integration.mjs", target] ] ++
  [ step (target ++ "-" ++ suite) (acceptance [suite, target])
  | suite <- ["integration", "algebra", "indexed", "gadt", "flow", "collections", "async", "domain", "packages", "refinement", "scalar"] ] ++
  -- The tutorial lessons have Java, Python and JavaScript tracks; the site
  -- also runs their TypeScript implementations.
  [ step (target ++ "-lessons") (acceptance ["lessons", target]) | target `elem` ["java", "python", "javascript", "typescript"] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32-compact") compact (acceptance [suite, target])
  | suite <- ["indexed", "domain", "packages", "algebra"] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32") [("LAWSPEC_MACHINE_BITS", "32")] (acceptance [suite, "--no-mutants", target])
  | suite <- ["refinement", "scalar"] ] ++
  [ step (target ++ "-native-bindings") ["node", "tools/native-example-integration.mjs", target]
  , Step (target ++ "-native-bindings-32-compact") compact ["node", "tools/native-example-integration.mjs", target] ] ++
  [ step "rust-layout" ["node", "tools/rust-layout-integration.mjs"] | target == "rust" ]
  where
    acceptance rest = ["stack", "--no-terminal", "exec", "lawspec-acceptance", "--"] ++ rest
    compact = [("LAWSPEC_MACHINE_BITS", "32"), ("LAWSPEC_MINIFY", "1")]

-- The shared Rust runtime crate in debug and release, and the Rust suites for
-- each additional toolchain or architecture requested.
rustRuntimeSteps :: Options -> [Step]
rustRuntimeSteps options =
  [ step ("rust-runtime-" ++ mode) (["cargo", "test", "--manifest-path", "runtime/rust/Cargo.toml", "--locked"] ++ ["--release" | mode == "release"])
  | "rust" `elem` targets options, mode <- ["debug", "release"] ] ++
  concat
    [ [ Step (label ++ "-runtime") env ["cargo", "test", "--manifest-path", "runtime/rust/Cargo.toml", "--locked"]
      , Step (label ++ "-scalar") (("LAWSPEC_MACHINE_BITS", bits) : env) acceptanceRust ]
    | toolchain <- if null (rustToolchains options) && not (null (rustTargets options)) then ["stable"] else rustToolchains options
    , architecture <- if null (rustTargets options) then [""] else rustTargets options
    , let label = "rust-" ++ toolchain ++ (if null architecture then "" else "-" ++ architecture)
          env = ("RUSTUP_TOOLCHAIN", toolchain) : [("CARGO_BUILD_TARGET", architecture) | not (null architecture)]
          bits = if "i686" `isPrefixOf` architecture then "32" else "64"
          acceptanceRust = ["stack", "--no-terminal", "exec", "lawspec-acceptance", "--", "scalar", "rust"] ]

runStep :: Step -> IO Bool
runStep (Step name env command) = do
  printf "%-40s " name
  hFlush stdout
  started <- getCurrentTime
  inherited <- getEnvironment
  root <- getCurrentDirectory
  gradle <- doesDirectoryExist localGradle
  -- A Gradle unpacked into .tools serves every step, not only the harness.
  let path = [(root </> localGradle) ++ ":" ++ maybe "" id (lookup "PATH" inherited) | gradle]
      overrides = env ++ [("PATH", p) | p <- path, "PATH" `notElem` map fst env]
      environment = overrides ++ [(k, v) | (k, v) <- inherited, k `notElem` map fst overrides]
  (code, out, err) <- case command of
    program : arguments -> readCreateProcessWithExitCode (proc program arguments) { env = Just environment } ""
    [] -> pure (ExitFailure 1, "", "empty command")
  finished <- getCurrentTime
  writeFile (logs </> map safe name ++ ".log") (unwords command ++ "\n\n" ++ out ++ err)
  let seconds = realToFrac (diffUTCTime finished started) :: Double
  printf "%s  %6.1fs\n" (if code == ExitSuccess then "ok  " else "FAIL" :: String) seconds
  when (code /= ExitSuccess) (putStrLn ("  " ++ lastLine (out ++ err)))
  pure (code == ExitSuccess)
  where
    safe c = if isAlphaNum c || c `elem` ("-._" :: String) then c else '_'
    lastLine text = case reverse (filter (not . null) (lines text)) of
      l : _ -> take 160 l
      [] -> ""

parse :: [String] -> Either String Options
parse = go (Options [] False False [] [])
  where
    go o [] = Right o { targets = if null (targets o) then allTargets else reverse (targets o) }
    go o ("--target" : t : rest)
      | t `elem` allTargets = go o { targets = t : targets o } rest
      | otherwise = Left ("unknown target: " ++ t)
    go o ("--core" : rest) = go o { coreOnly = True } rest
    go o ("--fail-fast" : rest) = go o { failFast = True } rest
    go o ("--rust-toolchains" : list : rest) = go o { rustToolchains = splitComma list } rest
    go o ("--rust-targets" : list : rest) = go o { rustTargets = splitComma list } rest
    go _ (flag : _) = Left ("unknown option: " ++ flag ++ "\nusage: lawspec-dev ci [--target T]... [--core] [--fail-fast] [--rust-toolchains a,b] [--rust-targets t,u]")
    splitComma s = case break (== ',') s of
      (a, _ : rest) -> a : splitComma rest
      (a, []) -> [a | not (null a)]

