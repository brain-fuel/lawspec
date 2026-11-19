-- | Running toolchains through the host's spawn, poll and kill effects, as
-- the Node CLI's spawn.mjs and child_process calls did: a command named
-- without a slash is looked up on PATH, and a missing one is reported with
-- spawn.mjs's message and remedy; a process runs to its exit while its
-- output is collected, echoed or both, within an optional wall-clock limit
-- and output limit; several processes run at once with their results in
-- the order they were started.
--
-- The ABI's spawn either inherits the host's environment or replaces it.
-- A process that needs variables added to it gets the host's whole
-- environment, read once per command by running @env -0@, with the
-- additions applied; the program itself stays @argv[0]@, so the sandbox's
-- program check still sees it.
-- ref:DEC-host-effect-abi ref:DEC-haskell-application-port
module LawSpec.App.Process
  ( Launch (..),
    Echo (..),
    Run (..),
    launch,
    resolveTool,
    notFoundMessage,
    toolOnPath,
    runProcess,
    runProcesses,
    execTool,
    commandFailed,
    runSucceeded,
    hostEnvironment,
    elapsedMilliseconds,
    monotonicMicroseconds',
  )
where

import Control.Monad (foldM, forM, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (toLower)
import Data.List (intercalate, isSuffixOf, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import LawSpec.App.Command
import LawSpec.App.Json (Json (..), member, parseJson)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, resolve)

-- | One process to start: the command as the Node CLI named it, which is
-- looked up on PATH unless it holds a slash.
data Launch = Launch
  { launchCommand :: String,
    launchArguments :: [String],
    launchDirectory :: FilePath,
    -- | Variables set (Just) or removed (Nothing) in the host's
    -- environment; none inherits it unchanged.
    launchEnvironment :: [(String, Maybe String)],
    launchInput :: Maybe B.ByteString,
    -- | Kill the process after this many milliseconds.
    launchTimeout :: Maybe Integer,
    -- | Kill the process once its two streams carry more bytes than this.
    launchLimit :: Maybe Int,
    launchEcho :: Echo
  }

-- | What reaches the CLI's own streams while the process runs: nothing; its
-- standard output on the given stream and its standard error on standard
-- error; or the same with Go's test2json events shown as the text they
-- carry (lawspec.mjs spawned()).
data Echo = Quiet | EchoTo Stream | EchoGoJson Stream
  deriving (Eq, Show)

data Run = Run
  { -- | How the process ended; 'Nothing' when it could not start, with the
    -- reason in 'runError'.
    runExit :: Maybe ExitStatus,
    runError :: Maybe String,
    runStdout :: B.ByteString,
    runStderr :: B.ByteString,
    runTimedOut :: Bool,
    runOverLimit :: Bool,
    runMicroseconds :: Integer,
    -- | Both streams, in the order their chunks arrived (spawned()'s
    -- output in lawspec test).
    runCombined :: B.ByteString
  }
  deriving (Eq, Show)

-- | A launch with the defaults: no input, no limits, nothing echoed.
launch :: String -> [String] -> FilePath -> Launch
launch command arguments directory = Launch command arguments directory [] Nothing Nothing Nothing Quiet

runSucceeded :: Run -> Bool
runSucceeded run = runExit run == Just (ExitCode 0) && not (runTimedOut run) && not (runOverLimit run)

-- | The host's environment, read once per command with @env -0@ and kept in
-- the session. Reading it changes nothing, so it does not count as an
-- effect a not-ported command must not have performed. It runs in a
-- directory the command may already read (a spawn's directory needs read
-- access), so it widens nothing.
hostEnvironment :: (Monad m) => FilePath -> Command m [(String, String)]
hostEnvironment directory = do
  kept <- sessionEnvironment <$> getSession
  case kept of
    Just environment -> pure environment
    Nothing -> do
      grantPrograms [envProgram]
      started <- effectUnobserved (Spawn (SpawnRequest [envProgram, "-0"] directory Nothing Nothing))
      environment <- case started of
        Left _ -> pure []
        Right handle -> parse <$> collect handle B.empty
      modifySession (\s -> s {sessionEnvironment = Just environment})
      pure environment
  where
    envProgram = "/usr/bin/env"
    collect handle kept = do
      events <- effectUnobserved (Poll [handle] 1000)
      case events of
        Left _ -> pure kept
        Right happened -> do
          let kept' = kept <> B.concat [bytes | Chunk _ Stdout bytes <- happened]
          if any exited happened then pure kept' else collect handle kept'
    exited = \case
      Exited {} -> True
      _ -> False
    parse bytes =
      [ (BC.unpack name, fromUtf8 (B.drop 1 value))
      | entry <- B.split 0 bytes,
        not (B.null entry),
        let (name, value) = BC.break (== '=') entry,
        not (B.null name)
      ]

-- | The environment a launch's process gets: inherited, or the host's with
-- the launch's changes.
environmentFor :: (Monad m) => Launch -> Command m (Maybe [(String, String)])
environmentFor spec
  | null (launchEnvironment spec) = pure Nothing
  | otherwise = do
      base <- hostEnvironment (launchDirectory spec)
      let changed = foldl' apply (M.fromList base, map fst base) (launchEnvironment spec)
          apply (values, order) (name, value) = case value of
            Just text -> (M.insert name text values, if name `elem` order then order else order ++ [name])
            Nothing -> (M.delete name values, filter (/= name) order)
      pure (Just [(name, value) | name <- snd changed, Just value <- [M.lookup name (fst changed)]])

-- | resolveCommand on a POSIX platform: an absolute or relative path is
-- taken as it is; a bare name is looked for in each PATH directory, in
-- order. 'Left' carries spawn.mjs's ToolNotFoundError message.
resolveTool :: (Monad m) => FilePath -> Maybe [(String, String)] -> String -> Command m (Either String FilePath)
resolveTool cwd environment command = do
  path' <- case environment of
    Just pairs -> pure (lookup "PATH" pairs)
    Nothing -> either (const Nothing) id <$> effectOr (GetEnvironment "PATH")
  let explicit = '/' `elem` command
      directories = nub [resolve cwd entry | entry <- splitOn ':' (fromMaybe "" path')]
      candidates = if explicit then [resolve cwd command] else [join directory command | directory <- directories]
  grantRead candidates
  found <- firstFile candidates
  pure $ case found of
    Just file -> Right file
    Nothing -> Left (notFoundMessage command explicit directories candidates)
  where
    firstFile = foldM (\kept file -> if isJust kept then pure kept else (\ok -> if ok then Just file else Nothing) <$> isRegularFile file) Nothing
    isRegularFile file =
      effectOr (Stat Follow file) >>= \case
        Right status -> pure (statusKind status == FileKind)
        Left _ -> pure False

-- | Whether a bare command is on PATH (a probe that runs nothing).
toolOnPath :: (Monad m) => FilePath -> String -> Command m Bool
toolOnPath cwd command = either (const False) (const True) <$> resolveTool cwd Nothing command

splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitOn separator rest

-- | spawn.mjs notFoundMessage, for a POSIX platform.
notFoundMessage :: String -> Bool -> [FilePath] -> [FilePath] -> String
notFoundMessage command explicit directories searched
  | explicit = command ++ " was not found; looked for " ++ (if null searched then command else intercalate ", " searched) ++ "; " ++ remedy command
  | otherwise = command ++ " was not found on PATH; " ++ (if null directories then "PATH names no directory" else "searched " ++ intercalate ", " directories) ++ "; " ++ remedy command

remedy :: String -> String
remedy command = case lookup name advice of
  Nothing -> "install " ++ command ++ " or add its directory to PATH"
  Just (Nothing, tool) -> "install " ++ tool ++ " or add its directory to PATH"
  Just (Just field, tool)
    | take 2 field == "--" -> "pass " ++ field ++ " <executable> or install " ++ tool
    | otherwise -> "set " ++ field ++ " in lawspec.edn or install " ++ tool
  where
    base = reverse (takeWhile (`notElem` ("/\\" :: String)) (reverse command))
    lowered = map toLower base
    name = case [stem | suffix <- [".exe", ".cmd", ".bat", ".com"], suffix `isSuffixOf` lowered, let stem = take (length lowered - 4) lowered] of
      stem : _ -> stem
      [] -> lowered
    advice =
      [ ("mvn", (Just ":maven", "Maven")),
        ("mvnw", (Just ":maven", "Maven")),
        ("gradle", (Just ":gradle", "Gradle")),
        ("gradlew", (Just ":gradle", "Gradle")),
        ("python", (Just ":python", "Python")),
        ("python3", (Just ":python", "Python")),
        ("cargo", (Just ":cargo", "Rust")),
        ("rustc", (Just ":rustc", "Rust")),
        ("scala", (Just ":scala", "Scala CLI")),
        ("clojure", (Just ":clojure", "the Clojure CLI")),
        ("swift", (Just ":swift", "Swift")),
        ("dotnet", (Just ":dotnet", "the .NET SDK")),
        ("node", (Nothing, "Node.js")),
        ("npm", (Nothing, "Node.js")),
        ("npx", (Nothing, "Node.js")),
        ("go", (Nothing, "Go")),
        ("stack", (Nothing, "Stack")),
        ("ghc", (Nothing, "GHC")),
        ("mix", (Nothing, "Elixir")),
        ("rebar3", (Nothing, "Rebar3")),
        ("erl", (Nothing, "Erlang/OTP")),
        ("erlc", (Nothing, "Erlang/OTP")),
        ("escript", (Nothing, "Erlang/OTP")),
        ("gleam", (Nothing, "Gleam")),
        ("java", (Nothing, "a JDK")),
        ("z3", (Just "--solver", "Z3"))
      ]

monotonicMicroseconds' :: (Monad m) => Command m Integer
monotonicMicroseconds' = either (const 0) monotonicMicroseconds <$> effectOr GetClock

elapsedMilliseconds :: Run -> Double
elapsedMilliseconds run = fromIntegral (runMicroseconds run) / 1000

-- | Run one process to its end.
runProcess :: (Monad m) => Launch -> Command m Run
runProcess spec = head' <$> runProcesses [spec]
  where
    head' runs = case runs of
      run : _ -> run
      [] -> Run Nothing (Just "no process") B.empty B.empty False False 0 B.empty

-- | One process's progress in the poll loop.
data Live = Live
  { liveHandle :: Maybe ProcessHandle,
    liveRun :: Run,
    liveStarted :: Integer,
    liveDeadline :: Maybe Integer,
    liveKilled :: Bool,
    liveBytes :: Int,
    -- | A partial line of Go's JSON events not shown yet.
    livePending :: B.ByteString,
    liveDone :: Bool
  }

-- | Start every launch, then poll them together until each has exited.
-- Echoed output is shown as it arrives, so echo from one process at a time.
runProcesses :: (Monad m) => [Launch] -> Command m [Run]
runProcesses specs = do
  -- The session's deadline (a nested invocation's time limit) bounds every
  -- process; past it, none starts.
  sessionLimit <- sessionDeadline <$> getSession
  started <- forM specs $ \spec -> do
    now <- monotonicMicroseconds'
    if maybe False (now >=) sessionLimit
      then do
        modifySession (\s -> s {sessionTimedOut = True})
        pure (Live Nothing (Run Nothing Nothing B.empty B.empty True False 0 B.empty) now Nothing False 0 B.empty True)
      else do
        environment <- environmentFor spec
        resolved <-
          if isAbsolute (launchCommand spec)
            then pure (Right (launchCommand spec))
            else resolveTool (launchDirectory spec) environment (launchCommand spec)
        case resolved of
          Left message -> pure (failed now message)
          Right program -> do
            grantPrograms [program]
            handle <- effectOr (Spawn (SpawnRequest (program : launchArguments spec) (launchDirectory spec) environment (launchInput spec)))
            let deadline = case (((\ms -> now + ms * 1000) <$> launchTimeout spec), sessionLimit) of
                  (Just own, Just limit) -> Just (min own limit)
                  (own, limit) -> maybe limit Just own
            pure $ case handle of
              Left problem -> failed now (spawnFailure spec program problem)
              Right h -> Live (Just h) (Run Nothing Nothing B.empty B.empty False False 0 B.empty) now deadline False 0 B.empty False
  finished <- loop started
  pure (map liveRun finished)
  where
    failed now message = Live Nothing (Run Nothing (Just message) B.empty B.empty False False 0 B.empty) now Nothing False 0 B.empty True
    loop lives
      | all liveDone lives = pure lives
      | otherwise = do
          now <- monotonicMicroseconds'
          sessionLimit <- sessionDeadline <$> getSession
          -- Kill whatever has passed its deadline.
          lives' <- forM lives $ \live -> case (liveHandle live, liveDeadline live) of
            (Just handle, Just deadline)
              | not (liveDone live),
                not (liveKilled live),
                now >= deadline -> do
                  _ <- effectOr (Kill handle)
                  when (maybe False (now >=) sessionLimit) (modifySession (\s -> s {sessionTimedOut = True}))
                  pure live {liveKilled = True, liveRun = (liveRun live) {runTimedOut = True}}
            _ -> pure live
          let waiting = [handle | live <- lives', not (liveDone live), Just handle <- [liveHandle live]]
              nearest = minimum (1000000 : [deadline - now | live <- lives', not (liveDone live), not (liveKilled live), Just deadline <- [liveDeadline live]])
              timeout = max 1 (fromInteger (min 1000 ((nearest + 999) `div` 1000)))
          events <- effectOr (Poll waiting timeout)
          case events of
            Left problem -> pure [if liveDone live then live else live {liveDone = True, liveRun = (liveRun live) {runError = Just (errorMessage problem)}} | live <- lives']
            Right happened -> do
              after <- monotonicMicroseconds'
              updated <- forM (zip specs lives') $ \(spec, live) -> foldM (event spec after) live [e | e <- happened, owner e == liveHandle live]
              loop updated
    owner = \case
      Chunk handle _ _ -> Just handle
      Exited handle _ -> Just handle
    event spec now live = \case
      Chunk _ stream bytes -> do
        let total = liveBytes live + B.length bytes
            run = liveRun live
        case launchLimit spec of
          Just limit
            | total > limit,
              not (liveKilled live) -> do
                mapM_ (\handle -> effectOr (Kill handle)) (liveHandle live)
                pure live {liveBytes = total, liveKilled = True, liveRun = run {runOverLimit = True}}
          _ | runOverLimit run -> pure live
          _ -> do
            pending <- echo (launchEcho spec) stream bytes (livePending live)
            pure
              live
                { liveBytes = total,
                  livePending = pending,
                  liveRun =
                    (if stream == Stdout then run {runStdout = runStdout run <> bytes} else run {runStderr = runStderr run <> bytes})
                      { runCombined = runCombined run <> bytes
                      }
                }
      Exited _ status -> do
        pure live {liveDone = True, livePending = B.empty, liveRun = (liveRun live) {runExit = Just status, runMicroseconds = now - liveStarted live}}
    echo mode stream bytes pending = case (mode, stream) of
      (Quiet, _) -> pure pending
      (_, Stderr) -> pending <$ writeBytes Stderr bytes
      (EchoTo shown, Stdout) -> pending <$ writeBytes shown bytes
      (EchoGoJson shown, Stdout) -> do
        let pieces = BC.split '\n' (pending <> bytes)
            (complete, rest) = (init pieces, last pieces)
        mapM_ (showEvent shown) complete
        pure rest
    showEvent shown line = case goOutput line of
      Just text -> writeBytes shown text
      Nothing -> writeBytes shown (line <> "\n")
    writeBytes stream bytes = when (not (B.null bytes)) (writeOutput stream bytes)

-- | One test2json event line as spawned() shows it: the event's Output when
-- it is a non-empty string, nothing for another JSON value, and the line
-- itself when it is not JSON.
goOutput :: B.ByteString -> Maybe B.ByteString
goOutput line = case parseJson (fromUtf8 line) of
  Left _ -> Nothing
  Right value -> Just (maybe B.empty utf8 (member "Output" value >>= nonEmpty))
  where
    nonEmpty = \case
      JString text | not (null text) -> Just text
      _ -> Nothing

-- | spawn.mjs's message for a process that could not start.
spawnFailure :: Launch -> FilePath -> HostError -> String
spawnFailure spec program problem = case errorKind problem of
  NotFound -> "spawn " ++ launchCommand spec ++ " ENOENT"
  PermissionDenied -> "spawn " ++ program ++ " EACCES"
  _ -> errorMessage problem

-- | execFile's error message for a process that failed: "Command failed:
-- <command and arguments>" and its standard error.
commandFailed :: Launch -> Run -> String
commandFailed spec run = case runError run of
  Just message -> message
  Nothing -> "Command failed: " ++ unwords (launchCommand spec : launchArguments spec) ++ "\n" ++ fromUtf8 (runStderr run)

-- | doctor.mjs run(): a tool's standard output, or execFile's failure.
execTool :: (Monad m) => Launch -> Command m (Either String String)
execTool spec = do
  run <- runProcess spec
  pure (if runSucceeded run then Right (fromUtf8 (runStdout run)) else Left (commandFailed spec run))
