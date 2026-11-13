-- | The complete LawSpec check, run locally from the repository root, since
-- the project has no hosted CI (ref:DEC-local-ci-only):
--
--   lawspec-dev ci                       everything, every target
--   lawspec-dev ci --target rust --target go
--   lawspec-dev ci --core                compiler, npm and editor checks only
--   lawspec-dev ci --fail-fast
--   lawspec-dev ci --fresh               ignore recorded results; run every step
--   lawspec-dev ci --rust-toolchains 1.85.0,stable --rust-targets i686-unknown-linux-gnu
--   lawspec-dev ci --jobs 6              at most six steps at once
--
-- Each step's output goes to .artifacts/ci/<step>.log; the console shows one
-- line per step and a summary. Every step runs even after a failure unless
-- --fail-fast is given, and the exit status is non-zero if any step failed.
--
-- Steps run in parallel, --jobs at a time (LAWSPEC_CI_JOBS, or half the
-- processors by default; ref:DEC-parallel-ci). --jobs 1 runs them one after
-- another, honoring the same prerequisites. In parallel, a line is printed as each step
-- finishes, so the order is the order of completion, and a terminal also
-- shows the running steps. Each step declares what it must follow and the
-- resources it shares (see plan): a target's environment in .integration, a
-- project directory under .artifacts, the repository's .stack-work, Stack's
-- snapshot database, the runtime crate's Cargo target, and the timing class
-- that bounds how many real-time suites run at once. Ctrl-C stops every
-- running step's process group. A step that runs past two hours
-- (LAWSPEC_CI_STEP_MINUTES) is stopped and fails, and on macOS the machine
-- is kept from idle sleep while the check runs.
--
-- The build step builds the library, the executables and the test suite
-- once. The compiler's tests run from that test executable in parts
-- (compilerTestShards), and each SDK test file is a step of its own
-- (ref:DEC-ci-test-targets).
--
-- Results are content-addressed. A core step that declares its inputs passes
-- without running when a pass was recorded for the same inputs: the bytes of
-- the repository files it reads (tracked or untracked, not ignored), its
-- command and environment, and the versions of its tools. Acceptance suites
-- key their own runs on the generated project (acceptance/Cache.hs), so a
-- compiler change that leaves a target's output unchanged skips its tests.
-- Parity binds the native and WASM executables, SDK, effective environment
-- and checked sources. Source/artifact correspondence is checked separately
-- by integrity and generation validation (ref:DEC-content-identity). An SDK
-- test file is keyed by the repository roots it can read and by the presence
-- and version of every tool it may start (sdkTestInputs). Package smoke
-- remains uncached: it resolves native dependencies afresh, which has no
-- frozen execution context.
-- Records live in .artifacts/cache; --fresh runs everything.
module Ci (ci) where

import Control.Concurrent (forkIO, killThread, myThreadId, threadDelay, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Exception (AsyncException(..), IOException, SomeException, evaluate, handle, mask, onException, throwIO, try)
import Control.Monad (filterM, forM, forM_, forever, mfilter, unless, void, when)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isAlphaNum, isDigit)
import Data.IORef
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, sort, stripPrefix, tails, transpose)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode(..), exitFailure, exitWith)
import System.FilePath ((</>))
import GHC.IO.Handle.Lock (LockMode(..), hLock, hTryLock)
import System.IO (Handle, IOMode(..), hClose, hFlush, hGetContents, hIsTerminalDevice, openFile, stdout)
import System.Posix.Signals (Handler(..), installHandler, signalProcessGroup, sigKILL, sigTERM)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)
import System.Posix.Types (ProcessGroupID)
import System.Process (CreateProcess(..), ProcessHandle, StdStream(..), createProcess, getPid, proc, readCreateProcessWithExitCode, terminateProcess, waitForProcess)
import Text.Printf (printf)
import qualified LawSpec.Targets as Targets
import Scheduler
import Ci.Cache (CacheResult(..), cachedCheck)

data Options = Options
  { targets :: [String], coreOnly :: Bool, failFast :: Bool, fresh :: Bool
  , rustToolchains :: [String], rustTargets :: [String], jobs :: Maybe Int }

allTargets :: [String]
allTargets = Targets.targets

-- | A step is a named command with extra environment, run from the root.
data Step = Step String [(String, String)] [String]

stepName :: Step -> String
stepName (Step name _ _) = name

-- | The SDK's test files, each a step of its own (ref:DEC-ci-test-targets).
sdkTestFiles :: IO [FilePath]
sdkTestFiles = do
  present <- doesDirectoryExist "npm/test"
  if present then sort . filter (".test.mjs" `isSuffixOf`) <$> listDirectory "npm/test" else pure []

sdkTestStep :: FilePath -> String
sdkTestStep file = "npm-test-" ++ take (length file - length (".test.mjs" :: String)) file

isSdkTest :: String -> Bool
isSdkTest = ("npm-test-" `isPrefixOf`)

isParity :: String -> Bool
isParity = ("parity-" `isPrefixOf`)

-- | The parts tools/parity.mjs runs with --part.
parityParts :: [String]
parityParts =
  ["base", "frontend-32", "frontend-64", "generation-32", "generation-32-compact", "generation-64", "generation-64-compact"]

isCompilerTest :: String -> Bool
isCompilerTest = ("compiler-tests-" `isPrefixOf`)

-- | The compiler's Hspec suite in parts that run at once. Measured alone
-- with the machine kept awake, the suite took 808 s: one proof-receipt
-- example 209 s, the SMT text group 134 s, the test manifest 130 s, and no
-- other group over 31 s. Those three run alone; nine middle-sized groups
-- (172 s together) share a part; the last part skips all of them, so a new
-- group is run without being named here. A pattern selects every example
-- whose path contains it, and the last part skips by the same patterns, so
-- each example runs in at least one part.
compilerTestShards :: [(String, [String])]
compilerTestShards =
  [ (name, concat [["--match", pattern] | pattern <- patterns]) | (name, patterns) <- named ] ++
  [ ("rest", concat [["--skip", pattern] | (_, patterns) <- named, pattern <- patterns]) ]
  where
    named =
      [ ("proof-receipts", ["proof receipts"])
      , ("smt-text", ["SMT text"])
      , ("test-manifest", ["the test manifest"])
      , ("generation", ["law sets", "compact generated test budgets", "canonical predicate facts", "BEAM generation"
        , "checked field predicate expansion", "independent native model layer selection", "RC1 canonical authoring"
        , "model checking", "canonical collections"]) ]

ci :: [String] -> IO ()
ci args = do
  options <- either (\message -> putStrLn message >> exitFailure) pure (parse args)
  workers <- maybe defaultJobs pure (jobs options)
  createDirectoryIfMissing True logs
  awake <- stayAwake
  limit <- stepLimit
  environments <- if coreOnly options then pure Nothing else Just <$> lockEnvironments
  repository <- repositoryFiles
  editor <- doesDirectoryExist "editors/vscode/node_modules"
  sdkTests <- sdkTestFiles
  let groups = stepGroups options editor sdkTests
      ordered = concatMap snd groups
      tasks = plan workers groups
  console <- newConsole (workers == 1)
  when (parallel console) $
    say console (show (length tasks) ++ " steps, at most " ++ show workers ++ " at once (--jobs).")
  children <- newIORef M.empty
  main' <- myThreadId
  -- SIGTERM stops the run as Ctrl-C does: every running step is stopped.
  _ <- installHandler sigTERM (Catch (throwTo main' UserInterrupt)) Nothing
  ticker <- if parallel console then Just <$> forkIO (forever (threadDelay 5000000 >> showRunning console)) else pure Nothing
  results <- handle (interrupted children) $
    schedule workers (failFast options) tasks
      (\task -> handle (stepError console (taskName task))
        (runCached console children limit (fresh options) repository (taskItem task)))
      (\t -> modifyIORef' (running console) (++ [taskName t]))
      (\t _ -> modifyIORef' (running console) (filter (/= taskName t)))
  mapM_ killThread ticker
  mapM_ terminateProcess awake
  -- Released here, so the handle (and its lock) lives through every step.
  mapM_ hClose environments
  -- Failures are named in the order of the steps, however they finished.
  let failedNames = S.fromList [name | (name, False) <- results]
      failed = [stepName s | s <- ordered, stepName s `S.member` failedNames]
  say console ""
  if null failed
    then say console "All checks passed."
    else do
      say console ("Failed: " ++ intercalate ", " failed)
      say console ("Logs: " ++ logs)
      exitWith (ExitFailure 1)

-- | Worktrees may share .integration through a link, and two runs must not
-- bootstrap or test in the same environments at once: a run holds an
-- exclusive lock on a file inside it (wherever the link resolves) until it
-- exits, and another waits.
lockEnvironments :: IO Handle
lockEnvironments = do
  createDirectoryIfMissing True ".integration"
  h <- openFile (".integration" </> ".lawspec-ci.lock") ReadWriteMode
  free <- hTryLock h ExclusiveLock
  unless free $ do
    putStrLn "Waiting for another lawspec-dev ci that uses .integration..."
    hFlush stdout
    hLock h ExclusiveLock
  pure h

-- | Keep the machine awake for the run. macOS idle-sleeps under a running
-- check when nobody touches the keyboard, and every step then stops with it.
-- caffeinate holds an idle-sleep assertion until this process exits (-w), so
-- an interrupted run releases it too. Other systems have no such command and
-- run as before.
stayAwake :: IO (Maybe ProcessHandle)
stayAwake = do
  present <- doesFileExist "/usr/bin/caffeinate"
  if not present then pure Nothing else do
    self <- getProcessID
    started <- try (createProcess (proc "/usr/bin/caffeinate" ["-i", "-w", show self]) { std_in = NoStream })
      :: IO (Either SomeException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
    pure (either (const Nothing) (\(_, _, _, handle') -> Just handle') started)

-- | The longest a step may run, in seconds: two hours, or
-- LAWSPEC_CI_STEP_MINUTES. A step past it is stopped and fails, so one hung
-- process cannot hold the run for a night. The longest step of a loaded full
-- run takes under an hour.
stepLimit :: IO Int
stepLimit = do
  configured <- lookupEnv "LAWSPEC_CI_STEP_MINUTES"
  pure $ 60 * case configured of
    Just n | not (null n), all isDigit n, read n > (0 :: Int) -> read n
    _ -> 120

-- | Half the processors: many steps run compilers that use several cores.
defaultJobs :: IO Int
defaultJobs = do
  configured <- lookupEnv "LAWSPEC_CI_JOBS"
  case configured of
    Just n | not (null n), all isDigit n, read n > (0 :: Int) -> pure (read n)
    _ -> max 1 . (`div` 2) <$> getNumProcessors

-- | The steps in their sequential order, each group with the target whose
-- environment it uses (Nothing for the repository-wide steps).
stepGroups :: Options -> Bool -> [FilePath] -> [(Maybe String, [Step])]
stepGroups options editor sdkTests =
  [(Nothing, coreSteps sdkTests)] ++
  [(Nothing, [step "editor-install" ["npm", "install", "--prefix", "editors/vscode", "--ignore-scripts", "--no-audit", "--no-fund"] | not editor]
    ++ [step "editor-grammar" ["npm", "test", "--prefix", "editors/vscode"]])] ++
  (if coreOnly options then [] else
    [(Nothing, [step "artifact-bootstrap" ["sh", "tools/artifact-targets.sh", "--setup"] |
        any (`elem` Targets.artifactTargets) (targets options)]
      ++ [step "beam-runtime" ["sh", "tools/beam-runtime.sh"] | any (`elem` Targets.beamTargets) (targets options)])
    , (Just "erlang", [step "beam-proper" ["sh", "tools/beam-proper.sh"] | "erlang" `elem` targets options])
    , (Just "elixir", [step "beam-stream-data" ["sh", "tools/beam-stream-data.sh"] | "elixir" `elem` targets options])
    , (Just "gleam", [step "beam-qcheck" ["sh", "tools/beam-qcheck.sh"] | "gleam" `elem` targets options]) ] ++
    [(Just target, targetSteps target) | target <- targets options] ++
    [(Just "rust", rustRuntimeSteps options)])

-- | What each step follows and claims when steps run in parallel.
--
-- Order: a target's steps follow its bootstrap, which creates
-- .integration/<target>, and the BEAM framework steps that may bootstrap it
-- too; every step that runs a built executable follows build; the SDK test
-- files follow the JavaScript/Python bootstraps (native cache and finite-loop
-- controls) and TypeScript bootstrap (they type-check with that tsc when present), and
-- beam-runtime the Python one (it runs that interpreter). Haskell, Java and
-- Clojure suites also follow the target's crypto suite, which runs alone
-- first: Stack installs the crypto extra-deps into its snapshot database and
-- Maven and the Clojure CLI download Bouncy Castle into ~/.m2, and none
-- guards concurrent installation. Other caches (Cargo, Go, Gradle, NuGet, npm) lock their own.
-- A step runs after those it follows have finished, passed or failed, so
-- every step still runs after a failure, as in the sequential run.
--
-- Claims: a bootstrap, and a BEAM framework step that may bootstrap, holds
-- its target's environment exclusively; every other step of the target
-- shares it. An acceptance suite holds its project directory
-- (.artifacts/<suite><profile>/<target>) exclusively, since the Rust
-- toolchain and architecture variants reuse the default projects. In the
-- repository's .stack-work, stack build may reconfigure and rebuild the
-- package and reinstall its executables, so the build step holds .stack-work
-- exclusively while the steps that run what it built share it. The build
-- step and the Haskell bootstrap and warm-up hold Stack's snapshot
-- database. The runtime crate's steps share one Cargo target directory.
-- Suites that wait on the real clock (actors, sessions, distribution and
-- their BEAM APIs, scheduling, resilience, workflows) are in the timing class, at most a
-- third of the jobs at once, so a loaded machine cannot starve many of them
-- together.
--
-- The order interleaves the targets, so different toolchains share the
-- processors rather than one toolchain taking every job.
plan :: Int -> [(Maybe String, [Step])] -> [Task Step]
plan workers groups = map task (alone ++ filter ((`notElem` aloneSteps) . stepName) (repositorySteps ++ interleaved))
  where
    -- A step that runs alone goes first, while nothing else runs; later, it
    -- would hold every step back behind the longest one running.
    alone = [s | s <- repositorySteps, stepName s `elem` aloneSteps]
    repositorySteps = concat [steps | (Nothing, steps) <- groups] ++ concat [steps | (Just _, steps@(Step name _ _ : _)) <- groups, name `elem` beamFrameworks]
    interleaved = concat (transpose [warmFirst target steps | (target, steps) <- byTarget])
    byTarget = M.toList (M.fromListWith (flip (++)) [(target, filter ((`notElem` beamFrameworks) . stepName) steps) | (Just target, steps) <- groups])
    warmFirst target steps = case break ((== warmUp target) . stepName) steps of
      (before, warm : after) | target `elem` warmTargets -> take 1 before ++ [warm] ++ drop 1 before ++ after
      _ -> steps
    targetOf = M.fromList [(stepName s, target) | (Just target, steps) <- groups, s <- steps]
    names = S.fromList (map stepName (concatMap snd groups))
    present n = n `S.member` names
    task s@(Step name env command) =
      Task
        name
        (filter present (follows name command (M.lookup name targetOf)))
        (claims name env command (M.lookup name targetOf))
        s
    follows name command target = case target of
      Nothing ->
        [bootstrap | isSdkTest name, bootstrap <- ["typescript-bootstrap", "javascript-bootstrap", "python-bootstrap"]]
          ++ ["build" | name /= "build", usesBuild command]
          ++ ["python-bootstrap" | name == "beam-runtime"]
          ++ ["editor-install" | name == "editor-grammar" || isSdkTest name]
          ++ ["docs" | name == "rejection-examples"]
          ++ ["learn-install" | name == "generated"]
          ++ ["generated" | name `elem` ["learn-assets", "code-style"]]
          ++ [prerequisite | name == "component-native-acceptance", prerequisite <- ["integrity", "generated"]]
          ++ ["learn-assets" | name `elem` ["learn-execution", "learn-browser", "package-smoke"] || isSdkTest name]
          ++ ["learn-execution" | name == "learn-browser"]
      Just t
        | t `elem` Targets.artifactTargets -> ["artifact-bootstrap", "build"]
        | name == t ++ "-bootstrap" || name `elem` beamFrameworks -> []
        | otherwise ->
            [t ++ "-bootstrap"]
              ++ ["build" | usesBuild command]
              ++ [f | (f, ft) <- zip beamFrameworks ["erlang", "elixir", "gleam"], ft == t]
              ++ [warmUp t | t `elem` warmTargets, name /= warmUp t]
              ++ ["python-bootstrap" | name == "swift-network-interoperability"]
    claims name env command target =
      [if name `elem` aloneSteps then Exclusive "machine" else Shared "machine"]
        ++ [Exclusive "stack-build" | buildsStack command]
        ++ [Exclusive "stack-work" | name `elem` stackBuilders]
        ++ [Exclusive "stack-snapshot" | name `elem` stackBuilders ++ ["haskell-bootstrap", warmUp "haskell"]]
        ++ [ Shared "stack-work"
           | name `notElem` stackBuilders,
             take 1 command == ["stack"] || name == "rejection-examples" || isParity name || isCompilerTest name
           ]
        ++ [Shared "env:python" | name `elem` ["beam-runtime", "swift-network-interoperability"] || isSdkTest name]
        ++ [Shared "env:javascript" | isSdkTest name]
        ++ [Shared "env:typescript" | isSdkTest name]
        ++ [Exclusive "env:artifacts" | name == "artifact-bootstrap"]
        ++
        -- The wrapper may repair its pinned environment after a failed bootstrap.
        [Exclusive "env:artifacts" | maybe False (`elem` Targets.artifactTargets) target]
        ++ [Exclusive "cargo:runtime/rust" | "runtime/rust/Cargo.toml" `elem` command]
        ++ [Counted "timing" (max 1 (workers `div` 3)) | timing name command]
        ++ maybe [] (\p -> [Exclusive ("project:" ++ p)]) (acceptanceProject env command)
        ++ case target of
          Just t
            | name == t ++ "-bootstrap" || name `elem` beamFrameworks -> [Exclusive ("env:" ++ t)]
            | otherwise -> [Shared ("env:" ++ t)]
          Nothing -> []
    stackBuilders = ["build"]
    -- stack run, build and test may configure and build the repository's
    -- package: stack test enables the test suite and the others disable it,
    -- and each switch recompiles the library. Only the build step builds;
    -- every other step uses stack exec, which runs what is installed.
    buildsStack command = case command of
      "stack" : "--no-terminal" : verb : _ -> verb `elem` ["run", "build", "test"]
      _ -> False
    -- A step that runs something the build step built.
    usesBuild command = take 1 command == ["stack"] || command == ["sh", "tools/beam-runtime.sh"]
      || take 2 command == ["sh", "tools/compiler-tests.sh"]
      || take 2 command == ["node", "tools/parity.mjs"]
    timing name command =
      name == "beam-runtime"
        || maybe False ((`elem` timingSuites) . fst) (acceptanceSuite command)

-- | Steps that run alone: package-smoke exports every bundled example under
-- a hang guard, single-threaded for minutes, and a loaded machine slows it
-- past any fixed guard. Component acceptance also performs full source
-- compilation, whose peak memory must not compete with other compiler jobs.
-- ref:DEC-node-precompiled-components
aloneSteps :: [String]
aloneSteps = ["package-smoke", "component-native-acceptance"]

-- | The BEAM steps that exercise a native property framework, bootstrapping
-- its target when the framework is missing.
beamFrameworks :: [String]
beamFrameworks = ["beam-proper", "beam-stream-data", "beam-qcheck"]

-- | Targets whose dependency caches are not safe to fill concurrently, and
-- the suite that fills them (the crypto suite needs every optional package).
warmTargets :: [String]
warmTargets = ["haskell", "java", "clojure"]

warmUp :: String -> String
warmUp target = target ++ "-crypto"

-- | Suites whose laws wait on the real clock: deadlines, receive timeouts,
-- handshakes and overlapping naps (the workflows suite times an all group).
timingSuites :: [String]
timingSuites =
  [ "actors", "restarts", "sessions", "distribution", "concurrent", "scheduling", "resilience", "consistency", "workflows"
  , "beam-remote-api", "beam-network-api", "beam-actor-api", "beam-session-api", "beam-mailbox-api" ]

-- | The suite and target of an acceptance command.
acceptanceSuite :: [String] -> Maybe (String, String)
acceptanceSuite command = case break (== "lawspec-acceptance") command of
  (_, _ : "--" : suite : rest) | [target] <- filter (not . ("--" `isPrefixOf`)) rest -> Just (suite, target)
  _ -> Nothing

-- | The project an acceptance suite writes: .artifacts/<suite><profile>/<target>.
acceptanceProject :: [(String, String)] -> [String] -> Maybe FilePath
acceptanceProject env command = do
  (suite, target) <- acceptanceSuite command
  let profile = (if lookup "LAWSPEC_MACHINE_BITS" env == Just "32" then "32" else "") ++
        (if lookup "LAWSPEC_MINIFY" env == Just "1" then "-compact" else "") ++
        maybe "" ('-' :) (mfilter (`notElem` ["", "lawspec"]) (lookup "LAWSPEC_ACTORS" env)) ++
        (if lookup "LAWSPEC_REMOTE" env == Just "cluster" then "-cluster" else "")
  pure (suite ++ profile ++ "/" ++ target)

-- | The console: in parallel, whole lines are printed as steps finish, and a
-- terminal shows the running steps on a status line that each line replaces.
data Console = Console
  { parallel :: Bool, terminal :: Bool, lock :: MVar (), status :: IORef Bool, running :: IORef [String] }

newConsole :: Bool -> IO Console
newConsole sequential = do
  tty <- hIsTerminalDevice stdout
  Console (not sequential) tty <$> newMVar () <*> newIORef False <*> newIORef []

-- | Print a line, replacing the status line.
say :: Console -> String -> IO ()
say console line = withMVar (lock console) $ \_ -> do
  shown <- readIORef (status console)
  when shown (putStr "\r\ESC[K" >> writeIORef (status console) False)
  putStrLn line
  hFlush stdout

showRunning :: Console -> IO ()
showRunning console = when (terminal console) $ withMVar (lock console) $ \_ -> do
  names <- readIORef (running console)
  unless (null names) $ do
    let text = "running " ++ show (length names) ++ ": " ++ intercalate ", " names
    putStr ("\r\ESC[K" ++ (if length text > 150 then take 147 text ++ "..." else text))
    hFlush stdout
    writeIORef (status console) True

-- | The process groups of running steps, by group id.
type Children = IORef (M.Map ProcessGroupID ())

-- | Ctrl-C (or SIGTERM): stop every running step's process group, politely
-- and then by force, and exit as an interrupted program does.
interrupted :: Children -> AsyncException -> IO a
interrupted children e = case e of
  UserInterrupt -> do
    let signal s = readIORef children >>= mapM_ (\g -> void (try (signalProcessGroup s g) :: IO (Either SomeException ()))) . M.keys
    signal sigTERM
    let wait n = do
          remaining <- readIORef children
          unless (M.null remaining || n <= (0 :: Int)) (threadDelay 100000 >> wait (n - 1))
    wait 30
    signal sigKILL
    putStrLn "\nInterrupted."
    exitWith (ExitFailure 130)
  _ -> throwIO e

logs :: FilePath
logs = ".artifacts/ci"

-- | A log or cache write can fail before runStep reports its result. Keep
-- the step and I/O error visible even when the log itself cannot be written.
stepError :: Console -> String -> IOException -> IO Bool
stepError console name error' = do
  say console (name ++ " FAIL: " ++ show error')
  pure False

localGradle :: FilePath
localGradle = ".tools/gradle-9.3.0/bin"

step :: String -> [String] -> Step
step name = Step name []

coreSteps :: [FilePath] -> [Step]
coreSteps sdkTests =
  [ -- One build serves every step: the library, the executables and the test
    -- suite, configured once. The steps after it run what it built.
    step "build" ["stack", "--no-terminal", "build", "--test", "--no-run-tests"],
    step "integrity" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "integrity"],
    step "boundaries" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "boundaries"],
    step "learn-install" ["npm", "ci", "--prefix", "learn"],
    step "generated" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "generate", "--check"],
    step "embedded-literals" ["stack", "--no-terminal", "exec", "--", "runghc", "-idev", "test/embed_literals.hs"],
    step "ci-cache-lifecycle" ["stack", "--no-terminal", "exec", "--", "runghc", "-idev", "dev/ci-cache-test/Main.hs"],
    step "version" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "version", "--check"],
    step "npm-lock" ["node", "tools/npm-lock.mjs", "--check"],
    step "learn-assets" ["node", "tools/learn-build.mjs"]
  ] ++
  [ step ("compiler-tests-" ++ name) (["sh", "tools/compiler-tests.sh"] ++ arguments)
  | (name, arguments) <- compilerTestShards ] ++
  [ step (sdkTestStep file) ["node", "--test", "npm/test/" ++ file] | file <- sdkTests ] ++
  [
    step "code-style" ["node", "tools/code-style.mjs", "--check", "learn/browser", "learn/formatting", "learn/test", "learn/exercises", "runtime", "templates/npm/mcp.mjs", "templates/npm/project.mjs", "templates/npm/learn.mjs", "templates/tools/code-style.mjs", "templates/tools/learn-build.mjs"],
    step "learn-browser" ["npm", "run", "test:browser", "--prefix", "learn"],
    step "learn-execution" ["npm", "test", "--prefix", "learn"]
  ] ++
  -- Native against WASM, response for response. All of it in one process
  -- took 113 minutes alone, so each part is a step.
  [ step ("parity-" ++ part) ["node", "tools/parity.mjs", "--part=" ++ part] | part <- parityParts ] ++
  [
    step "package-smoke" ["node", "tools/package-smoke.mjs"],
    step "component-native-acceptance" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "native-check"],
    step "docs" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "docs", "--check"],
    step "rejection-examples" ["node", "tools/rejection-examples.mjs"],
    -- canon keeps its own content-addressed cache, so this step is never skipped.
    step "canon" ["stack", "--no-terminal", "exec", "lawspec-dev", "--", "canon", "check"]
  ]

-- | The repository files a core step reads, as roots to keep or drop (an empty
-- keep list keeps every file), and the commands whose output names its tools.
data Inputs = Inputs [FilePath] [FilePath] [[String]]

stepInputs :: String -> Maybe Inputs
stepInputs name = case name of
  -- Hspec reads acceptance specs, bindings and fixtures. Its context probe
  -- also binds the selected tools, optional solver and actual SDK artifacts.
  _ | isCompilerTest name ->
    Just
      ( Inputs
          []
          (["npm/", "tools/", "docs/", "editors/"] ++ ledgers)
          [["node", "tools/ci-artifact-key.mjs", "compiler-tests"]]
      )
  -- An SDK test file is a step of its own. Its inputs are chosen in stepKey
  -- (sdkTestInputs), and the probe binds the tools it may start: the tests
  -- select optional native tools by availability, so each tool's presence
  -- and version is part of the key.
  _ | isSdkTest name -> Just (Inputs [] [] [["node", "tools/ci-artifact-key.mjs", "npm-tests"]])
  _ | isParity name ->
    Just
      ( Inputs
          [ "tools/parity.mjs",
            "tools/ci-artifact-key.mjs",
            "examples/specs/",
            "examples/packages/",
            "test/fixtures/artifact-configuration.lawspec",
            "test/fixtures/artifact-antlr-inputs.lawspec",
            "test/fixtures/artifact-antlr-indexed-input.lawspec",
            "npm/starter-rc1.lawspec"
          ]
          []
          [["node", "tools/ci-artifact-key.mjs", "parity"]]
      )
  "npm-lock" ->
    Just
      ( Inputs
          [ "tools/npm-lock.mjs",
            "npm/package.json",
            "npm/package-lock.json",
            "component/native-packages.json"
          ]
          []
          [["node", "--version"]]
      )
  "package-smoke" -> Nothing
  -- Native archives are ignored build products and can change independently of
  -- tracked source. Never substitute a cached pass for executing this package.
  "component-native-acceptance" -> Nothing
  "docs" -> Just (Inputs [] ["acceptance/", "editors/", "npm/", "tools/"] [])
  "rejection-examples" ->
    Just
      ( Inputs
          [ "dev/Docs.hs",
            "src/",
            "package.yaml",
            "templates/site/",
            "templates/tools/rejection-examples.mjs",
            "tools/rejection-examples.mjs",
            "test/fixtures/canonical-rejection-"
          ]
          []
          [["node", "--version"], ["stack", "--version"]]
      )
  "rust-runtime-debug" -> Just rustRuntime
  "rust-runtime-release" -> Just rustRuntime
  "beam-runtime" ->
    Just
      ( Inputs
          [ "runtime/lawspec_beam_",
            "runtime/lawspec_network.erl",
            "runtime/lawspec_crypto_",
            "runtime/defaults/vectors.txt",
            "test/fixtures/beam/",
            "test/fixtures/recorded-values.json",
            "dev/BeamVectors.hs",
            "tools/beam-crypto-build.py",
            "tools/beam-runtime.sh",
            "tools/beam-values-reference.py",
            "tools/beam-secure-interoperability.py",
            "tools/beam-coverage-check.mjs",
            "npm/beam-coverage.mjs",
            "runtime/lawspec_runtime.py",
            "runtime/lawspec_network.py",
            "test/locks/python.txt",
            "examples/specs/distribution.lawspec",
            "src/LawSpec/Core/",
            "src/LawSpec/Core.hs",
            "src/LawSpec/Scalar.hs",
            "src/LawSpec/Regex.hs"
          ]
          []
          [ ["erl", "-noshell", "-eval", "io:format(\"~s~n\", [erlang:system_info(system_version)]), halt()."],
            ["erl", "-noshell", "-eval", "io:format(\"~tp~n\", [crypto:info_lib()]), halt()."],
            ["cc", "--version"],
            ["stack", "--version"],
            ["python3", "--version"],
            ["node", "--version"]
          ]
      )
  "swift-network-interoperability" ->
    Just
      ( Inputs
          [ "runtime/swift/LawSpecRuntime/",
            "runtime/lawspec_runtime.py",
            "runtime/lawspec_network.py",
            "test/fixtures/swift/",
            "tools/swift-network-interoperability.py",
            "test/locks/python.txt"
          ]
          []
          [["swift", "--version"], [".integration/python/.venv/bin/python", "--version"]]
      )
  "beam-proper" ->
    Just
      ( Inputs
          [ "runtime/lawspec_beam_",
            "test/fixtures/beam/",
            "tools/beam-proper.sh",
            "test/locks/erlang/",
            "src/LawSpec/Scaffold.hs",
            "templates/tools/bootstrap-integration.mjs"
          ]
          []
          [ ["erl", "-noshell", "-eval", "io:format(\"~s~n\", [erlang:system_info(system_version)]), halt()."],
            ["rebar3", "version"]
          ]
      )
  "beam-stream-data" ->
    Just
      ( Inputs
          [ "runtime/lawspec_beam_",
            "test/fixtures/beam/",
            "tools/beam-stream-data.sh",
            "test/locks/elixir/",
            "src/LawSpec/Scaffold.hs",
            "templates/tools/bootstrap-integration.mjs"
          ]
          []
          [["elixir", "--version"], ["mix", "--version"]]
      )
  "beam-qcheck" ->
    Just
      ( Inputs
          [ "runtime/lawspec_beam_",
            "test/fixtures/beam/",
            "tools/beam-qcheck.sh",
            "test/locks/gleam/",
            "src/LawSpec/Scaffold.hs",
            "templates/tools/bootstrap-integration.mjs"
          ]
          []
          [["gleam", "--version"], ["erl", "-noshell", "-eval", "io:format(\"~s~n\", [erlang:system_info(system_version)]), halt()."]]
      )
  -- The artifact validators pin yamllint in their script and require
  -- OpenTofu 1.13.1, whose version keys the step with the other tools.
  _
    | name `elem` [t ++ "-artifact-validation" | t <- Targets.artifactTargets] ->
        Just (Inputs [] unread [["tofu", "version"], ["java", "-version"], ["make", "--version"], ["python3", "--version"]])
  _ -> Nothing
  where
    unread = ["docs/", "acceptance/", "editors/"] ++ ledgers
    -- canon's ledgers and profile: only canon, docs and generate read them.
    ledgers = ["canon.yaml", "canonical_"]
    rustRuntime = Inputs ["runtime/rust/", "runtime/lawspec_runtime.rs"] [] [["rustc", "-Vv"], ["cargo", "-V"]]

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
runCached :: Console -> Children -> Int -> Bool -> [FilePath] -> Step -> IO Bool
runCached console children limit freshRun repository current@(Step name env command) =
  case stepInputs name of
    Nothing -> runStep console children limit (if freshRun then refreshed else current)
    Just inputs -> do
      key <- stepKey repository current inputs
      case key of
        Nothing -> runStep console children limit current
        Just digest -> do
          result <- cachedCheck freshRun (cacheStore </> digest)
            (logs </> map safeName name ++ ".log") (runStep console children limit current)
          case result of
            CacheHit -> say console (printf "%-40s %s" name ("cached" :: String)) >> pure True
            Checked passed -> pure passed
  where refreshed = Step name (("LAWSPEC_CACHE", "refresh") : env) command

stepKey :: [FilePath] -> Step -> Inputs -> IO (Maybe String)
stepKey repository (Step name env command) (Inputs keep drop' probes) = do
  selected <- if isSdkTest name then sdkTestInputs repository (last command) else pure
    [ f | f <- repository
    , null keep || any (`isPrefixOf` f) keep
    , not (any (`isPrefixOf` f) drop') ]
  contents <- forM selected $ \path -> (,) path <$> fileDigest path
  effective <- stepEnvironment env
  answers <- forM probes $ \probe -> case probe of
    program : arguments -> observed (probe, env) $ do
      result <- try (readCreateProcessWithExitCode ((proc program arguments){env = Just effective}) "") :: IO (Either IOException (ExitCode, String, String))
      pure $ case result of
        Right (ExitSuccess, out, err) -> Just (unwords probe ++ "\n" ++ out ++ err)
        _ -> Nothing
    [] -> pure (Just "")
  -- A missing or failed identity probe cannot certify a cached result. Run
  -- the actual check and leave it uncached rather than hash an error message.
  pure $ do
    tools <- sequence answers
    let pieces = map BC.pack ("lawspec-ci-cache-2" : name : unwords command : show env : tools) ++
          concat [[BC.pack path, digest] | (path, digest) <- contents]
        framed piece = [BC.pack (show (B.length piece) ++ ":"), piece]
    pure (concatMap (printf "%02x") (B.unpack (SHA.finalize (SHA.updates SHA.init (concatMap framed pieces)))))

-- | A file's SHA-256, computed once in a run: many steps read the same files,
-- and the SDK test steps alone would otherwise read the repository once each.
fileDigest :: FilePath -> IO B.ByteString
fileDigest path = do
  known <- M.lookup path <$> readIORef fileDigests
  case known of
    Just digest -> pure digest
    Nothing -> do
      digest <- SHA.hash <$> B.readFile path
      atomicModifyIORef' fileDigests (\m -> (M.insert path digest m, digest))

fileDigests :: IORef (M.Map FilePath B.ByteString)
fileDigests = unsafePerformIO (newIORef M.empty)
{-# NOINLINE fileDigests #-}

-- | An identity probe's answer, asked once in a run for a command and step
-- environment. The lock makes the steps that start together wait for one
-- probe rather than each start twenty tools.
observed :: ([String], [(String, String)]) -> IO (Maybe String) -> IO (Maybe String)
observed probe ask = modifyMVar observations $ \known -> case M.lookup probe known of
  Just answer -> pure (known, answer)
  Nothing -> do
    answer <- ask
    pure (M.insert probe answer known, answer)

observations :: MVar (M.Map ([String], [(String, String)]) (Maybe String))
observations = unsafePerformIO (newMVar M.empty)
{-# NOINLINE observations #-}

-- | The repository files an SDK test file may read, as Bazel and Make name a
-- target's inputs so that an unchanged target is not rebuilt
-- (ref:DEC-ci-test-targets). Nothing records what a test process opens, so
-- the inputs are a declared over-approximation, by repository root:
--
--   * the SDK itself (npm/), without the other test files;
--   * the environment locks (test/locks/);
--   * a root directory when the test file, a test helper or an SDK module
--     names it as a path segment in a string ('runtime/', "../examples");
--   * the Haskell sources and build files when the test file names stack, a
--     .hs or .cabal file, GHC or one of the repository's executables. Every
--     other test runs the committed core.wasm, whose bytes are in npm/;
--   * the files at the repository root, except the changelog and canon's
--     ledgers unless the test names them.
--
-- A source's first line is skipped: it is the generated-file notice, which
-- names lawspec-dev in every file.
sdkTestInputs :: [FilePath] -> FilePath -> IO [FilePath]
sdkTestInputs repository own = do
  let isTest f = "npm/test/" `isPrefixOf` f && ".test.mjs" `isSuffixOf` f
      sdkModule f = "npm/" `isPrefixOf` f && ".mjs" `isSuffixOf` f && not (isTest f)
        && all (`notElem` splitPath f) ["node_modules", "learn", "examples"]
      body f = BC.unpack . BC.drop 1 . BC.dropWhile (/= '\n') <$> B.readFile f
  ownText <- body own
  shared <- concat <$> mapM body (filter sdkModule repository)
  let quote c = c `elem` ("/'\"`" :: String)
      names text word = any (\rest -> case rest of
        before : found | quote before, Just (after : _) <- stripPrefix word found -> quote after
        _ -> False) (tails text)
      haskell = any (`isInfixOf` ownText)
        ["'stack'", "\"stack\"", ".hs'", ".hs\"", ".hs`", ".cabal", "ghc", "lawspec-core", "lawspec-dev", "lawspec-acceptance", "LAWSPEC_CORE"]
      haskellFile f = any (`isPrefixOf` f) ["src/", "app/"] || any (`isSuffixOf` f) [".hs", ".cabal"]
        || f `elem` ["stack.yaml", "stack.yaml.lock", "package.yaml"]
      ledger f = f == "CHANGELOG.md" || f == "canon.yaml" || "canonical_" `isPrefixOf` f
      root f = takeWhile (/= '/') f
      mentioned = M.fromList [(r, names ownText r || names shared r) | r <- S.toList (S.fromList (map root repository))]
      input f
        | "npm/" `isPrefixOf` f = f == own || not (isTest f)
        | "test/locks/" `isPrefixOf` f = True
        | haskellFile f = haskell
        | '/' `notElem` f = not (ledger f) || names ownText f || f `isInfixOf` ownText
        | otherwise = M.findWithDefault True (root f) mentioned
  pure (filter input repository)
  where splitPath = words . map (\c -> if c == '/' then ' ' else c)

-- | The profiles match the acceptance matrix: suites run with mutants in the
-- default profile, and with the 32-bit (and compact) profiles as well.
-- Shared-failure regression families: ref:DEC-s1j-shared-failures.
targetSteps :: String -> [Step]
targetSteps target | target `elem` Targets.artifactTargets =
  [step (target ++ "-artifact-validation") ["sh", "tools/artifact-targets.sh", target]]
targetSteps target =
  [ step (target ++ "-bootstrap") ["node", "tools/bootstrap-integration.mjs", target] ] ++
  [ Step (target ++ "-" ++ suite ++ suffix) env (acceptance [suite,target])
  | suite <- ["s1j-strategies","s1j-host"],
    (suffix,env) <- [("",[]),("-32-compact",compact)] ] ++
  [ Step ("go-s1j-handlers" ++ suffix) env (acceptance ["s1j",target])
  | target == "go", (suffix,env) <- [("",[]),("-32-compact",compact)] ] ++
  [ step "jvm-finite-cover" ["python3", "-B", "test/finite_cases_jvm.py"] | target == "java" ] ++
  [ step "go-finite-cover" ["python3", "-B", "test/finite_cases_go.py"] | target == "go" ] ++
  [ step "haskell-finite-cover" ["stack", "--no-terminal", "exec", "--", "runghc", "-iruntime", "test/finite_cases_haskell.hs"] | target == "haskell" ] ++
  [ step "swift-finite-cover" ["python3", "-B", "test/finite_cases_swift.py"] | target == "swift" ] ++
  [ step "dotnet-finite-cover" ["python3", "-B", "test/finite_cases_dotnet.py"] | target == "fsharp" ] ++
  [ step "scala-native-constructors" ["python3", "-B", "test/scala_no_arg_constructors.py"] | target == "scala" ] ++
  [ Step name [("PYTHONPATH","runtime")] [".integration/prolog/.venv/bin/python", "-B", file]
  | target == "prolog", (name,file) <- [("prolog-runtime","test/prolog_runtime.py"),
      ("prolog-execution-reporting","test/prolog_reporting.py")] ] ++
  [ Step ("prolog-bridge" ++ suffix) env (acceptance ["prolog-bridge",target])
  | target == "prolog", (suffix,env) <- [("",[]),("-32-compact",compact)] ] ++
  [ Step ("prolog-cli" ++ suffix) env ["node","tools/prolog-cli-integration.mjs"]
  | target == "prolog", (suffix,env) <- [("",[]),("-32-compact",compact)] ] ++
  [ Step (target ++ "-business-refunds-orders" ++ suffix) env (acceptance ["business-refunds-orders",target])
  | (suffix,env) <- [("",[]),("-32-compact",compact)] ] ++
  [ step (target ++ "-index-paths") ["python3", "tools/index-path-conformance.py", target] ] ++
  [ Step (target ++ "-native-record-layouts") [("LAWSPEC_NATIVE_LAYOUT_TARGET",target)]
      ["node","--test","--test-name-pattern=^" ++ target ++ " native layouts", "npm/test/native-static-layouts.test.mjs"]
  | target `elem` ["java","kotlin","scala","groovy","rust","go","haskell","fsharp","swift","erlang","elixir","gleam"] ] ++
  [ Step "rust-dynamic-embedding" [("LAWSPEC_NATIVE_LAYOUT_TARGET","rust")]
      ["node","--test","npm/test/rust-dynamic-embedding.test.mjs"]
  | target == "rust" ] ++
  [ Step "rust-native-failure-products" [("LAWSPEC_NATIVE_LAYOUT_TARGET","rust")]
      ["node","--test","--test-name-pattern=^Rust mapped record failures", "npm/test/native-failure-products.test.mjs"]
  | target == "rust" ] ++
  [ Step "clojure-native-failure-products" [("LAWSPEC_NATIVE_LAYOUT_TARGET","clojure")]
      ["node","--test","--test-name-pattern=^Clojure mapped record failures", "npm/test/native-failure-products.test.mjs"]
  | target == "clojure" ] ++
  [ Step (target ++ "-existential-native-profiles" ++ suffix) env (acceptance ["minor-existential-native-profiles", target])
  | target `elem` ["go","haskell"], (suffix,env) <- [("", []), ("-32-compact", compact)] ] ++
  [ step (target ++ "-recorded-runtime") ["node", "test/fixtures/recorded-web.mjs"]
  | target `elem` ["javascript", "typescript"] ] ++
  [ step "python-recorded-runtime" [".integration/python/.venv/bin/python", "-B", "test/fixtures/recorded_python.py"]
  | target == "python" ] ++
  [ Step ("python-chapter6-oracles" ++ suffix) env ["node", "tools/chapter6-oracles.mjs", "--property"]
  | target == "python", (suffix,env) <- [("", []), ("-32-compact", compact)] ] ++
  -- A Swift node and a Python node exchange values live over TCP, each
  -- through its own runtime's secure transport.
  [ step "swift-network-interoperability" [".integration/python/.venv/bin/python", "-B", "tools/swift-network-interoperability.py"]
  | target == "swift" ] ++
  [ Step (target ++ "-recorded" ++ suffix) env (acceptance ["recorded", target])
  | (suffix, env) <- [("", []), ("-32-compact", compact)] ] ++
  [ step (target ++ "-" ++ suite) (acceptance [suite, target])
  | suite <- ["integration", "definitions", "mutual-recursion", "text-pieces", "list-mapping", "rc1-nesting", "rc1-codec", "rc1-native-names", "rc1-existence", "rc1-composition", "rc1-empty-domains", "rc1-recursive-records", "rc1-record-payloads", "minor-empty-record-patterns", "minor-stateful-initializers", "minor-positional-products", "minor-branch-admission", "minor-gadt-payload-indices", "minor-existential-records", "minor-container-records", "minor-refined-gadt-indices", "minor-record-predicate-functions", "minor-native-failure-products", "minor-refined-primitive-inputs", "minor-smt-arithmetic", "minor-typed-mappings", "minor-unicode-filenames", "minor-exact-widening", "minor-bounded-generators", "rc1-record-refinements", "rc1-metadata", "rc1-references", "rc1-witnesses", "rc1-integer-domains", "rc1-search", "rc1-eq-set-foundation", "rc1-eq-set-operations", "rc1-sets", "rc1-set-literals", "rc1-set-domains", "rc1-set-generation", "rc1-collection-membership", "rc1-prelude-names", "algebra", "indexed", "gadt", "flow", "collections", "async", "railway", "domain", "workflows", "keywords", "durations", "resilience", "generation", "models", "concurrent", "handles", "asyncbindings", "abilities", "handlerbindings", "builtins", "crypto", "matchers", "failures", "tables", "resources", "harness", "scheduling", "sessions", "actors", "restarts", "consistency", "distribution", "packages", "refinement", "scalar", "records", "sequences", "composition", "contracts"] ] ++
  -- The tutorial lessons have Java, Python and JavaScript tracks; the site
  -- also runs their TypeScript, F#, C# and Swift implementations.
  [ step (target ++ "-lessons") (acceptance ["lessons", target]) | target `elem` ["java", "python", "javascript", "typescript", "fsharp", "csharp", "swift"] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32-compact") compact (acceptance [suite, target])
  | suite <- ["indexed", "domain", "mutual-recursion", "text-pieces", "list-mapping", "rc1-nesting", "rc1-codec", "rc1-native-names", "rc1-existence", "rc1-composition", "rc1-empty-domains", "rc1-recursive-records", "rc1-record-payloads", "minor-empty-record-patterns", "minor-stateful-initializers", "minor-positional-products", "minor-branch-admission", "minor-gadt-payload-indices", "minor-existential-records", "minor-container-records", "minor-refined-gadt-indices", "minor-record-predicate-functions", "minor-native-failure-products", "minor-refined-primitive-inputs", "minor-smt-arithmetic", "minor-typed-mappings", "minor-unicode-filenames", "minor-exact-widening", "minor-bounded-generators", "rc1-record-refinements", "rc1-metadata", "rc1-references", "rc1-witnesses", "rc1-integer-domains", "rc1-search", "rc1-eq-set-foundation", "rc1-eq-set-operations", "rc1-sets", "rc1-set-literals", "rc1-set-domains", "rc1-set-generation", "rc1-collection-membership", "rc1-prelude-names", "packages", "algebra", "definitions"] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32") [("LAWSPEC_MACHINE_BITS", "32")] (acceptance [suite, "--no-mutants", target])
  | suite <- ["refinement", "scalar"] ] ++
  [ Step (target ++ "-" ++ suite ++ suffix) env (acceptance [suite, target])
  | target `elem` Targets.beamTargets,
    suite <- ["beam-native-shapes", "beam-native-codecs", "beam-native-calls",
      "beam-failures", "beam-bound-failures", "beam-mapped-failures", "beam-handler-context", "beam-builtin-context", "beam-crypto-context", "beam-async-workflows", "beam-policy-context", "beam-remote-api", "beam-network-api", "beam-actor-api", "beam-session-api", "beam-mailbox-api",
      "beam-strategies", "beam-adequacy", "beam-status", "beam-target", "beam-repetition", "beam-selection", "beam-benchmarks",
      "beam-resources", "beam-shared-resources", "beam-resource-owners", "beam-embedding"],
    (suffix,env) <- [("", []), ("-32-compact", compact)] ] ++
  [ Step (target ++ "-" ++ suite ++ "-32-compact") compact (acceptance [suite, target])
  | target `elem` Targets.beamTargets, suite <- ["abilities", "handlerbindings", "builtins", "crypto", "async", "failures", "workflows", "resilience",
      "models", "concurrent", "handles", "consistency", "actors", "sessions", "distribution", "scheduling", "matchers", "tables", "keywords", "durations", "flow",
      "integration", "collections", "railway", "generation", "asyncbindings", "refinement",
      "records", "sequences", "composition", "contracts"] ] ++
  -- The JVM targets' actors again on Apache Pekko (:actors {:runtime :pekko}),
  -- with the same laws and mutants. ref:DEC-pekko-runtime
  [ Step (target ++ "-" ++ suite ++ "-pekko") [("LAWSPEC_ACTORS", "pekko")] (acceptance [suite, target])
  | target `elem` ["java", "kotlin", "scala", "groovy", "clojure"], suite <- ["actors", "restarts"] ] ++
  -- And through the Spring Boot actor starter (:runtime :spring), which is
  -- for Java and Kotlin, reused by Groovy and Clojure.
  -- ref:DEC-spring-actor-starter
  [ Step (target ++ "-" ++ suite ++ "-spring") [("LAWSPEC_ACTORS", "spring")] (acceptance [suite, target])
  | target `elem` ["java", "kotlin", "groovy", "clojure"], suite <- ["actors", "restarts"] ] ++
  -- Actors served and called over Pekko Cluster (:remote :cluster): the
  -- distribution suite's remote laws on a two-node cluster in one JVM, on
  -- Pekko for every JVM target and through the Spring starter for Java.
  -- ref:DEC-pekko-cluster-remote
  [ Step (target ++ "-distribution-" ++ runtime ++ "-cluster") [("LAWSPEC_ACTORS", runtime), ("LAWSPEC_REMOTE", "cluster")]
      (acceptance ["distribution", target])
  | (runtime, targets) <- [("pekko", ["java", "kotlin", "scala", "groovy", "clojure"]), ("spring", ["java"])]
  , target `elem` targets ] ++
  -- Scala's own suites: bound handlers whose operations fail answer Either.
  [ step (target ++ "-" ++ suite) (acceptance [suite, target]) | target == "scala", suite <- ["scala-bound-handlers"] ] ++
  -- Existing Pekko actors checked against a LawSpec actor's model (Java and
  -- Scala), and an existing Spring starter actor (Java).
  [ step (target ++ "-" ++ suite) (acceptance [suite, target]) | target `elem` ["java", "scala"], suite <- ["pekko-native-actors"] ] ++
  [ step (target ++ "-" ++ suite) (acceptance [suite, target]) | target == "java", suite <- ["pekko-native-actors-spring"] ] ++
  -- apache/pekko-samples, vendored unchanged and checked through native
  -- actor bindings, on Java and Scala. ref:DEC-pekko-sample-suites
  [ step (target ++ "-pekko-sample-" ++ sample) (acceptance ["pekko-samples/" ++ sample, target])
  | target `elem` ["java", "scala"], sample <- ["fsm", "persistence", "sharding"] ] ++
  [ step (target ++ "-native-bindings") ["node", "tools/native-example-integration.mjs", target]
  , Step (target ++ "-native-bindings-32-compact") compact ["node", "tools/native-example-integration.mjs", target] ] ++
  [ Step (target ++ "-model-layer-selection" ++ suffix) env ["node", "tools/model-layer-integration.mjs", target]
  | (suffix, env) <- [("", []), ("-32-compact", compact)] ] ++
  [ Step (target ++ "-crypto-cli" ++ suffix) env ["node", "tools/beam-crypto-integration.mjs", target]
  | target `elem` Targets.beamTargets, (suffix, env) <- [("", []), ("-32-compact", compact)] ] ++
  [ Step (target ++ "-model-cli" ++ suffix) env ["node", "tools/beam-model-integration.mjs", target]
  | target `elem` Targets.beamTargets, (suffix, env) <- [("", []), ("-32-compact", compact)] ] ++
  [ Step (target ++ "-harness-cli" ++ suffix) env ["node", "tools/beam-harness-integration.mjs", target]
  | target `elem` Targets.beamTargets, (suffix, env) <- [("", []), ("-32-compact", compact)] ] ++
  [ step "javascript-multi-project-replay" ["node", "tools/multi-project-replay.mjs"] | target == "javascript" ] ++
  [ Step (target ++ "-multi-project-replay" ++ suffix)
      (env ++ [("LAWSPEC_EXUNIT_MAX_FAILURES", "1") | target == "elixir"])
      ["node", "tools/multi-project-replay.mjs", target]
  | target `elem` Targets.beamTargets, (suffix, env) <- [("", []), ("-32-compact", compact)] ] ++
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

-- | Run a step in a process group of its own, so an interrupted run can stop
-- it and everything it started. Sequentially, the step's name is printed as it
-- starts and its result when it ends, on one line; in parallel the whole line
-- is printed when it ends.
runStep :: Console -> Children -> Int -> Step -> IO Bool
runStep console children limit (Step name env command) = do
  unless (parallel console) $ do
    printf "%-40s " name
    hFlush stdout
  started <- getCurrentTime
  environment <- stepEnvironment env
  (code, out, err) <- case command of
    program : arguments -> do
      result <- try (runGroup children limit (proc program arguments) { env = Just environment })
      pure (either (\e -> (ExitFailure 1, "", show (e :: SomeException))) id result)
    [] -> pure (ExitFailure 1, "", "empty command")
  finished <- getCurrentTime
  let outcome = case code of
        ExitSuccess -> "Exit status: 0"
        ExitFailure status -> "Exit status: " ++ show status ++
          (if status < 0 then " (terminated by signal " ++ show (negate status) ++ ")" else "")
  writeFile (logs </> map safeName name ++ ".log")
    (unwords command ++ "\n\n" ++ out ++ err ++ "\n" ++ outcome ++ "\n")
  let seconds = realToFrac (diffUTCTime finished started) :: Double
      result = printf "%s  %6.1fs" (if code == ExitSuccess then "ok  " else "FAIL" :: String) seconds :: String
      details = if code == ExitSuccess then [] else
        ("  " ++ outcome) : ["  " ++ lastLine (out ++ err) | not (null (out ++ err))]
  if parallel console
    then say console (intercalate "\n" (printf "%-40s %s" name result : details))
    else mapM_ (say console) (result : details)
  pure (code == ExitSuccess)
  where
    lastLine text = case reverse (filter (not . null) (lines text)) of
      l : _ -> take 160 l
      [] -> ""

-- | Identity probes and checks receive exactly the same executable search
-- path and overrides, including the repository's pinned Gradle installation.
stepEnvironment :: [(String, String)] -> IO [(String, String)]
stepEnvironment env = do
  inherited <- getEnvironment
  root <- getCurrentDirectory
  gradle <- doesDirectoryExist localGradle
  -- A Gradle unpacked into .tools serves every step, not only the harness.
  let path = [(root </> localGradle) ++ ":" ++ maybe "" id (lookup "PATH" inherited) | gradle]
      overrides = env ++ [("PATH", p) | p <- path, "PATH" `notElem` map fst env]
      environment = overrides ++ [(k, v) | (k, v) <- inherited, k `notElem` map fst overrides]
  pure environment

-- | Run a process as the leader of a new process group, with its output
-- captured as readCreateProcessWithExitCode captures it (standard input is
-- empty), and the group recorded while it runs. Close unrelated descriptors
-- so persistent build servers cannot inherit the CI environment lock.
runGroup :: Children -> Int -> CreateProcess -> IO (ExitCode, String, String)
runGroup children limit process = do
  (input, out, err, child) <- mask $ \_ -> do
    (Just input, Just out, Just err, child) <- createProcess process
      { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe
      , create_group = True, close_fds = True }
    pid <- getPid child
    forM_ pid $ \g -> modifyIORef' children (M.insert (fromIntegral g) ())
    pure (input, out, err, child)
  let forget = getPid child >>= mapM_ (\g -> modifyIORef' children (M.delete (fromIntegral g)))
  expired <- newIORef False
  -- Past the limit the whole group is stopped, politely and then by force.
  -- The group id is signalled only while it is still recorded as running.
  let stop s = do
        group <- getPid child
        running' <- readIORef children
        forM_ group $ \g -> when (M.member (fromIntegral g) running') $
          void (try (signalProcessGroup s (fromIntegral g)) :: IO (Either SomeException ()))
  timer <- forkIO $ do
    threadDelay (limit * 1000000)
    writeIORef expired True
    stop sigTERM
    threadDelay 5000000
    stop sigKILL
  flip onException (killThread timer >> forget) $ do
    hClose input
    errors <- newEmptyMVar
    _ <- forkIO (try (hGetContents err >>= \s -> evaluate (length s) >> pure s) >>= putMVar errors)
    output <- hGetContents out
    _ <- evaluate (length output)
    errorText <- takeMVar errors >>= either (\e -> throwIO (e :: SomeException)) pure
    -- The group is forgotten before the child is reaped, so its id is never
    -- signalled after it could be reused.
    killThread timer
    forget
    code <- waitForProcess child
    late <- readIORef expired
    pure (code, output, errorText ++
      (if late then "\nStopped: the step ran past its limit of " ++ show (limit `div` 60) ++ " minutes (LAWSPEC_CI_STEP_MINUTES).\n" else ""))

safeName :: Char -> Char
safeName c = if isAlphaNum c || c `elem` ("-._" :: String) then c else '_'

parse :: [String] -> Either String Options
parse = go (Options [] False False False [] [] Nothing)
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
    go o ("--jobs" : n : rest)
      | not (null n), all isDigit n, read n > (0 :: Int) = go o { jobs = Just (read n) } rest
      | otherwise = Left ("--jobs takes a positive number, not " ++ n)
    go _ (flag : _) = Left ("unknown option: " ++ flag ++ "\nusage: lawspec-dev ci [--target T]... [--core] [--fail-fast] [--fresh] [--jobs N] [--rust-toolchains a,b] [--rust-targets t,u]")
    splitComma s = case break (== ',') s of
      (a, _ : rest) -> a : splitComma rest
      (a, []) -> [a | not (null a)]
