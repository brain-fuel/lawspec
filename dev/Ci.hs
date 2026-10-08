-- | The complete LawSpec check, run locally from the repository root, since
-- the project has no hosted CI (ref:DEC-local-ci-only):
--
--   lawspec-dev ci                       everything, every target
--   lawspec-dev ci --target rust --target go
--   lawspec-dev ci --core                compiler, npm and editor checks only
--   lawspec-dev ci --fail-fast
--   lawspec-dev ci --fresh               ignore recorded results; run every step
--   lawspec-dev ci --rust-toolchains 1.85.0,stable --rust-targets i686-unknown-linux-gnu
--
-- Each step's output goes to .artifacts/ci/<step>.log; the console shows one
-- line per step and a summary. Every step runs even after a failure unless
-- --fail-fast is given, and the exit status is non-zero if any step failed.
--
-- Results are content-addressed. A core step that declares its inputs passes
-- without running when a pass was recorded for the same inputs: the bytes of
-- the repository files it reads (tracked or untracked, not ignored), its
-- command and environment, and the versions of its tools. Acceptance suites
-- key their own runs on the generated project (acceptance/Cache.hs), so a
-- compiler change that leaves a target's output unchanged skips its tests.
-- Records live in .artifacts/cache; --fresh runs everything, as releases do.
module Ci (ci) where

import Control.Monad (filterM, forM, unless, when)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isAlphaNum)
import Data.IORef
import Data.List (intercalate, isPrefixOf, sort)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..), exitFailure, exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.Process (CreateProcess(..), proc, readCreateProcessWithExitCode)
import Text.Printf (printf)
import qualified LawSpec.Targets as Targets

data Options = Options
  { targets :: [String], coreOnly :: Bool, failFast :: Bool, fresh :: Bool
  , rustToolchains :: [String], rustTargets :: [String] }

allTargets :: [String]
allTargets = Targets.targets

-- | A step is a named command with extra environment, run from the root.
data Step = Step String [(String, String)] [String]

stepName :: Step -> String
stepName (Step name _ _) = name

ci :: [String] -> IO ()
ci args = do
  options <- either (\message -> putStrLn message >> exitFailure) pure (parse args)
  createDirectoryIfMissing True logs
  failures <- newIORef []
  repository <- repositoryFiles
  let run current = do
        stop <- if failFast options then not . null <$> readIORef failures else pure False
        unless stop $ do
          ok <- runCached (fresh options) repository current
          unless ok (modifyIORef failures (stepName current :))
  mapM_ run coreSteps
  editor <- doesDirectoryExist "editors/vscode/node_modules"
  mapM_ run ([step "editor-install" ["npm", "install", "--prefix", "editors/vscode", "--ignore-scripts", "--no-audit", "--no-fund"] | not editor]
    ++ [step "editor-grammar" ["npm", "test", "--prefix", "editors/vscode"]])
  unless (coreOnly options) $ do
    mapM_ run [step "build-acceptance" ["stack", "--no-terminal", "build", "lawspec:exe:lawspec-acceptance"]]
    when (any (`elem` Targets.beamTargets) (targets options)) $
      run (step "beam-runtime" ["sh", "tools/beam-runtime.sh"])
    when ("erlang" `elem` targets options) $
      run (step "beam-proper" ["sh", "tools/beam-proper.sh"])
    when ("elixir" `elem` targets options) $
      run (step "beam-stream-data" ["sh", "tools/beam-stream-data.sh"])
    when ("gleam" `elem` targets options) $
      run (step "beam-qcheck" ["sh", "tools/beam-qcheck.sh"])
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
  , step "docs" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "docs", "--check"]
  -- canon keeps its own content-addressed cache, so this step is never skipped.
  , step "canon" ["stack", "--no-terminal", "run", "lawspec-dev", "--", "canon", "check"] ]

-- | The repository files a core step reads, as roots to keep or drop (an empty
-- keep list keeps every file), and the commands whose output names its tools.
data Inputs = Inputs [FilePath] [FilePath] [[String]]

stepInputs :: String -> Maybe Inputs
stepInputs name = case name of
  "compiler-tests" -> Just (Inputs [] (["npm/", "tools/"] ++ unread) [["stack", "--version"]])
  "npm-tests" -> Just (Inputs ["npm/", "examples/", "test/fixtures/"] [] [["node", "--version"]])
  "parity" -> Just (Inputs [] unread [["node", "--version"]])
  "package-smoke" -> Just (Inputs [] unread [["node", "--version"], ["npm", "--version"]])
  "docs" -> Just (Inputs [] ["acceptance/", "editors/", "npm/", "tools/"] [])
  "rust-runtime-debug" -> Just rustRuntime
  "rust-runtime-release" -> Just rustRuntime
  "beam-runtime" -> Just (Inputs ["runtime/lawspec_beam_", "runtime/lawspec_crypto_", "runtime/defaults/vectors.txt",
    "test/fixtures/beam/", "dev/BeamVectors.hs", "tools/beam-crypto-build.py",
    "tools/beam-runtime.sh", "tools/beam-values-reference.py", "runtime/lawspec_runtime.py",
    "src/LawSpec/Core/", "src/LawSpec/Core.hs", "src/LawSpec/Scalar.hs", "src/LawSpec/Regex.hs"] []
    [["erl", "-noshell", "-eval", "io:format(\"~s~n\", [erlang:system_info(system_version)]), halt()."],
     ["erl", "-noshell", "-eval", "io:format(\"~tp~n\", [crypto:info_lib()]), halt()."],
     ["cc", "--version"], ["stack", "--version"], ["python3", "--version"]])
  "beam-proper" -> Just (Inputs ["runtime/lawspec_beam_", "test/fixtures/beam/", "tools/beam-proper.sh",
    "test/locks/erlang/", "src/LawSpec/Scaffold.hs", "templates/tools/bootstrap-integration.mjs"] []
    [["erl", "-noshell", "-eval", "io:format(\"~s~n\", [erlang:system_info(system_version)]), halt()."],
     ["rebar3", "version"]])
  "beam-stream-data" -> Just (Inputs ["runtime/lawspec_beam_", "test/fixtures/beam/", "tools/beam-stream-data.sh",
    "test/locks/elixir/", "src/LawSpec/Scaffold.hs", "templates/tools/bootstrap-integration.mjs"] []
    [["elixir", "--version"], ["mix", "--version"]])
  "beam-qcheck" -> Just (Inputs ["runtime/lawspec_beam_", "test/fixtures/beam/", "tools/beam-qcheck.sh",
    "test/locks/gleam/", "src/LawSpec/Scaffold.hs", "templates/tools/bootstrap-integration.mjs"] []
    [["gleam", "--version"], ["erl", "-noshell", "-eval", "io:format(\"~s~n\", [erlang:system_info(system_version)]), halt()."]])
  _ -> Nothing
  where
    unread = ["docs/", "acceptance/", "editors/"]
    rustRuntime = Inputs ["runtime/rust/"] [] [["rustc", "-Vv"], ["cargo", "-V"]]

-- | Every file git would commit: tracked or untracked, and not ignored.
repositoryFiles :: IO [FilePath]
repositoryFiles = do
  (code, out, _) <- readCreateProcessWithExitCode
    (proc "git" ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) ""
  if code /= ExitSuccess then pure [] else
    filterM doesFileExist (sort (filter (not . null) (splitOn '\0' out)))
  where
    splitOn c s = case break (== c) s of
      (a, _ : rest) -> a : splitOn c rest
      (a, []) -> [a]

cacheStore :: FilePath
cacheStore = ".artifacts/cache/ci"

-- | Run a step unless a pass is recorded for its inputs. Under --fresh every
-- step runs (acceptance suites with LAWSPEC_CACHE=refresh), and passes are
-- still recorded for later runs.
runCached :: Bool -> [FilePath] -> Step -> IO Bool
runCached freshRun repository current@(Step name env command) =
  case stepInputs name of
    Nothing -> runStep (if freshRun then refreshed else current)
    Just inputs -> do
      key <- stepKey repository current inputs
      let recorded = cacheStore </> key
      hit <- if freshRun then pure False else doesFileExist recorded
      if hit
        then do
          printf "%-40s %s\n" name ("cached" :: String)
          copyFile recorded (logs </> map safeName name ++ ".log")
          pure True
        else do
          ok <- runStep current
          when ok $ do
            createDirectoryIfMissing True cacheStore
            copyFile (logs </> map safeName name ++ ".log") recorded
          pure ok
  where refreshed = Step name (("LAWSPEC_CACHE", "refresh") : env) command

stepKey :: [FilePath] -> Step -> Inputs -> IO String
stepKey repository (Step name env command) (Inputs keep drop' probes) = do
  let selected = [ f | f <- repository
                 , null keep || any (`isPrefixOf` f) keep
                 , not (any (`isPrefixOf` f) drop') ]
  contents <- forM selected $ \path -> (,) path <$> B.readFile path
  tools <- forM probes $ \probe -> case probe of
    program : arguments -> do
      (_, out, err) <- readCreateProcessWithExitCode (proc program arguments) ""
      pure (unwords probe ++ "\n" ++ out ++ err)
    [] -> pure ""
  let pieces = map BC.pack ("lawspec-ci-cache-1" : name : unwords command : show env : tools) ++
        concat [[BC.pack path, bytes] | (path, bytes) <- contents]
      framed piece = [BC.pack (show (B.length piece) ++ ":"), piece]
  pure (concatMap (printf "%02x") (B.unpack (SHA.finalize (SHA.updates SHA.init (concatMap framed pieces)))))

-- | The profiles match the acceptance matrix: suites run with mutants in the
-- default profile, and with the 32-bit (and compact) profiles as well.
targetSteps :: String -> [Step]
targetSteps target =
  [ step (target ++ "-bootstrap") ["node", "tools/bootstrap-integration.mjs", target] ] ++
  [ step (target ++ "-" ++ suite) (acceptance [suite, target])
  | suite <- ["integration", "definitions", "algebra", "indexed", "gadt", "flow", "collections", "async", "railway", "domain", "workflows", "keywords", "durations", "resilience", "generation", "models", "concurrent", "handles", "asyncbindings", "abilities", "handlerbindings", "builtins", "crypto", "matchers", "failures", "tables", "resources", "harness", "scheduling", "sessions", "actors", "consistency", "distribution", "packages", "refinement", "scalar"] ] ++
  -- The tutorial lessons have Java, Python and JavaScript tracks; the site
  -- also runs their TypeScript implementations.
  [ step (target ++ "-lessons") (acceptance ["lessons", target]) | target `elem` ["java", "python", "javascript", "typescript"] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32-compact") compact (acceptance [suite, target])
  | suite <- ["indexed", "domain", "packages", "algebra", "definitions"] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32") [("LAWSPEC_MACHINE_BITS", "32")] (acceptance [suite, "--no-mutants", target])
  | suite <- ["refinement", "scalar"] ] ++
  [ Step (target ++ "-" ++ suite ++ suffix) env (acceptance [suite, target])
  | target `elem` Targets.beamTargets,
    suite <- ["beam-native-shapes", "beam-native-codecs", "beam-native-calls",
      "beam-failures", "beam-bound-failures", "beam-mapped-failures", "beam-handler-context", "beam-builtin-context", "beam-crypto-context", "beam-async-workflows"],
    (suffix,env) <- [("", []), ("-32-compact", compact)] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32-compact") compact (acceptance [suite, target])
  | target `elem` Targets.beamTargets, suite <- ["abilities", "handlerbindings", "builtins", "crypto", "async", "failures"] ] ++
  [ step (target ++ "-native-bindings") ["node", "tools/native-example-integration.mjs", target]
  , Step (target ++ "-native-bindings-32-compact") compact ["node", "tools/native-example-integration.mjs", target] ] ++
  [ step "rust-layout" ["node", "tools/rust-layout-integration.mjs"] | target == "rust" ]
  where
    acceptance rest = ["stack", "--no-terminal", "exec", "lawspec-acceptance", "--"] ++ rest
    compact = [("LAWSPEC_MACHINE_BITS", "32"), ("LAWSPEC_MINIFY", "1")]

-- | The shared Rust runtime crate in debug and release, and the Rust suites for
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
  writeFile (logs </> map safeName name ++ ".log") (unwords command ++ "\n\n" ++ out ++ err)
  let seconds = realToFrac (diffUTCTime finished started) :: Double
  printf "%s  %6.1fs\n" (if code == ExitSuccess then "ok  " else "FAIL" :: String) seconds
  when (code /= ExitSuccess) (putStrLn ("  " ++ lastLine (out ++ err)))
  pure (code == ExitSuccess)
  where
    lastLine text = case reverse (filter (not . null) (lines text)) of
      l : _ -> take 160 l
      [] -> ""

safeName :: Char -> Char
safeName c = if isAlphaNum c || c `elem` ("-._" :: String) then c else '_'

parse :: [String] -> Either String Options
parse = go (Options [] False False False [] [])
  where
    go o [] = Right o { targets = if null (targets o) then allTargets else reverse (targets o) }
    go o ("--target" : t : rest)
      | t `elem` allTargets = go o { targets = t : targets o } rest
      | otherwise = Left ("unknown target: " ++ t)
    go o ("--core" : rest) = go o { coreOnly = True } rest
    go o ("--fail-fast" : rest) = go o { failFast = True } rest
    go o ("--fresh" : rest) = go o { fresh = True } rest
    go o ("--rust-toolchains" : list : rest) = go o { rustToolchains = splitComma list } rest
    go o ("--rust-targets" : list : rest) = go o { rustTargets = splitComma list } rest
    go _ (flag : _) = Left ("unknown option: " ++ flag ++ "\nusage: lawspec-dev ci [--target T]... [--core] [--fail-fast] [--fresh] [--rust-toolchains a,b] [--rust-targets t,u]")
    splitComma s = case break (== ',') s of
      (a, _ : rest) -> a : splitComma rest
      (a, []) -> [a | not (null a)]
