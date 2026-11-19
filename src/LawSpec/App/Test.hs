-- | lawspec test, ported from the Node CLI's runTests (bin/lawspec.mjs):
-- run the generated tests of the laws whose results may have changed since
-- their last passing run, through each target's own runner, and record
-- each law's attempt, its result key and seed, and the failure database.
--
-- Each target is prepared and run in order, and within a target each batch
-- and each of its invocations in order, as the legacy CLI ran them: a later
-- step depends on an earlier one's outcome (a batch that could not start
-- stops the run; a failed target stops the command), and a runner's output
-- is shown as it arrives, on standard output (standard error under
-- --json), so only one runner runs at a time.
--
-- Result keys name the host that ran the core where the legacy CLI named
-- the Node binary and SDK files that ran it ("LawSpec.App.TestResults"
-- hostIdentity); everything else a key holds is as the legacy CLI's.
-- ref:DEC-haskell-application-port ref:DEC-content-identity ref:DEC-s1j-shared-failures
module LawSpec.App.Test
  ( runTests,
    projectDigest,
    environmentDigest,
    recordedDigest,
    failureDatabase,
    executedTests,
    projectKey,
    cryptoBuildOutput,
    isAttestation,
    readAttestation,
  )
where

import Control.Monad (foldM, forM, forM_, unless, when)
import qualified Data.ByteString as B
import Data.Char (isDigit)
import Data.List (isPrefixOf, isSuffixOf, nub, sortBy)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Scientific (toRealFloat)
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Doctor (doctor)
import LawSpec.App.Files (artifactsFrom, atomicWrite, compareUtf16, planChanges, planWrites, readOptional)
import LawSpec.App.Json
import LawSpec.App.Process
import LawSpec.App.Project (buildDigest, isoTime)
import LawSpec.App.TestCoverage
import LawSpec.App.TestReports
import LawSpec.App.TestResults
import LawSpec.App.TestRuns
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, relative, resolve, takeDirectory)
import LawSpec.Scaffold (scaffoldFiles)

-- | Build and lock files, which choose the toolchain and dependencies.
environmentFiles :: [String]
environmentFiles =
  [ "package.json",
    "package-lock.json",
    "tsconfig.json",
    "pyproject.toml",
    "go.mod",
    "go.sum",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "Cargo.toml",
    "Cargo.lock",
    "stack.yaml",
    "stack.yaml.lock",
    "package.yaml",
    "rebar.config",
    "rebar.config.script",
    "rebar.lock",
    "mix.exs",
    "mix.lock",
    "gleam.toml",
    "manifest.toml",
    "global.json",
    "Directory.Build.props",
    "Directory.Packages.props",
    "NuGet.config",
    "project.scala",
    "Package.swift",
    "Package.resolved"
  ]

-- | input-files.mjs buildDirectories: never part of a project's identity.
buildDirectories :: [String]
buildDirectories =
  [ ".git",
    ".lawspec",
    "node_modules",
    "dist",
    "build",
    "target",
    "out",
    ".gradle",
    "bin",
    "obj",
    "TestResults",
    ".stack-work",
    "_build",
    "deps",
    ".elixir_ls",
    "__pycache__",
    ".hypothesis",
    ".pytest_cache",
    ".venv",
    "venv",
    ".idea",
    ".vscode",
    ".scala-build",
    ".bsp",
    ".bloop",
    ".metals",
    ".build",
    ".swiftpm",
    ".cpcache"
  ]

-- | The generated crypto builder's outputs:
-- /(?:^|\/)priv\/lawspec_crypto_native\.(?:so|dll)(?:\.build|\.\d+\.tmp)?$/
cryptoBuildOutput :: String -> Bool
cryptoBuildOutput file = any matchesAt (positions file)
  where
    stem = "priv/lawspec_crypto_native."
    positions text = [rest | (i, rest) <- zip [0 :: Int ..] (suffixes text), stem `isPrefixOf` rest, i == 0 || take 1 (drop (i - 1) text) == "/"]
    suffixes s = case s of
      [] -> []
      _ : more -> s : suffixes more
    matchesAt rest =
      let afterStem = drop (length stem) rest
       in any (\ext -> maybe False tailOk (stripPrefix' ext afterStem)) ["so", "dll"]
    tailOk t =
      null t || t == ".build" || case stripPrefix' "." t of
        Just more -> case span isDigit more of
          (_ : _, ".tmp") -> True
          _ -> False
        Nothing -> False
    stripPrefix' prefix text = if prefix `isPrefixOf` text then Just (drop (length prefix) text) else Nothing

-- | Whether a JSON file is an environment attestation (an observation,
-- never an implementation input).
isAttestation :: String -> Bool
isAttestation content = case parseJson content of
  Right value@(JObject _) -> member "format" value == Just (JString "environment-attestation")
  _ -> False

-- | path.resolve(root).digest, first 12 characters (failure-database.mjs).
projectKey :: FilePath -> String
projectKey root = take 12 (digestHex (digest (utf8 root)))

sha :: B.ByteString -> String
sha = digestHex . digest

-- | A target's scaffold files in the readable and the compact layout.
templates :: String -> (M.Map FilePath String, M.Map FilePath String)
templates language =
  ( either (const M.empty) M.fromList (scaffoldFiles False language),
    either (const M.empty) M.fromList (scaffoldFiles True language)
  )

-- | Entries of a directory, sorted as JavaScript sorts names.
sortedEntries :: [Entry] -> [Entry]
sortedEntries = sortBy (\a b -> compareUtf16 (entryName a) (entryName b))

listOrFail :: (Monad m) => FilePath -> Command m [Entry]
listOrFail folder = effect (nodeFailure "scandir" folder) (ListDirectory folder)

readOrFail :: (Monad m) => FilePath -> Command m B.ByteString
readOrFail file = effect (nodeFailure "open" file) (ReadFile file)

-- | projectDigest: every file in a project that LawSpec did not generate,
-- by content, except environment attestations; a byte-exact compact
-- scaffold counts as its readable form. Declared inputs outside the
-- project add their digests.
projectDigest :: (Monad m) => FilePath -> [String] -> String -> FilePath -> Json -> Command m String
projectDigest root generated language inputRoot inputs = do
  let (readable, compact') = templates language
  parts <- walk readable compact' ""
  external <- case inputs of
    JArray [] -> pure []
    _ -> do
      rows <- fingerprintInputs inputRoot inputs [resolve root file | file <- generated]
      pure [(file, hex) | (file, hex) <- rows, outside (resolve inputRoot file)]
  let tail' =
        if null external && inputs == JArray []
          then []
          else [utf8 "declared-inputs\0", utf8 (compact (JArray [JArray [JString f, JString h] | (f, h) <- external])), utf8 "\0"]
  pure (sha (B.concat (parts ++ tail')))
  where
    outside file =
      let rel = relative (resolve "/" root) file
       in rel == ".." || "../" `isPrefixOf` rel || isAbsolute rel
    walk readable compact' folder = do
      entries <- sortedEntries <$> listOrFail (if null folder then root else join root folder)
      concat
        <$> forM
          entries
          ( \(Entry name kind) -> do
              let rel = if null folder then name else folder ++ "/" ++ name
              case kind of
                DirectoryKind
                  | name `notElem` buildDirectories && not ("testdata/rapid" `isSuffixOf` rel) -> walk readable compact' rel
                  | otherwise -> pure []
                FileKind
                  | rel `notElem` generated && not (cryptoBuildOutput rel) -> do
                      content <- readOrFail (join root rel)
                      let text = fromUtf8 content
                      if ".json" `isSuffixOf` rel && isAttestation text
                        then pure []
                        else
                          pure
                            [ utf8 (rel ++ "\0"),
                              if Just text == M.lookup rel compact' then utf8 (fromMaybe "" (M.lookup rel readable)) else content,
                              utf8 "\0"
                            ]
                _ -> pure []
          )

-- | input-files.mjs fingerprintInputs: each declared input file's digest,
-- by its path relative to the input root, sorted.
fingerprintInputs :: (Monad m) => FilePath -> Json -> [FilePath] -> Command m [(String, String)]
fingerprintInputs root inputs generated = do
  entries <- case inputs of
    JArray items | all nonEmptyText items -> pure [text | JString text <- items]
    _ -> failWith "Component inputs must be an array of nonempty paths"
  grantRead [resolve root entry | entry <- entries]
  rows <- foldM (\kept entry -> visit kept (resolve root entry) entry) [] entries
  pure (sortBy (\(a, _) (b, _) -> compareUtf16 a b) rows)
  where
    nonEmptyText = \case
      JString (_ : _) -> True
      _ -> False
    visit kept file rel = do
      info <- effect (nodeFailure "lstat" file) (Stat NoFollow file)
      case statusKind info of
        SymbolicLinkKind -> failWith ("Symbolic links are not supported in component inputs: " ++ rel)
        DirectoryKind -> do
          entries <- sortBy compareUtf16 . map entryName <$> listOrFail file
          foldM
            ( \acc name ->
                if name `elem` buildDirectories || ("testdata/rapid" `isSuffixOf` (rel ++ "/" ++ name))
                  then pure acc
                  else visit acc (join file name) (rel ++ "/" ++ name)
            )
            kept
            entries
        FileKind
          | file `notElem` generated && not (cryptoBuildOutput rel) -> do
              content <- readOrFail file
              if ".json" `isSuffixOf` rel && isAttestation (fromUtf8 content)
                then pure kept
                else pure (assignRow kept rel (sha content))
        _ -> pure kept
    assignRow kept rel hex
      | any ((== rel) . fst) kept = [(k, if k == rel then hex else v) | (k, v) <- kept]
      | otherwise = kept ++ [(rel, hex)]

-- | environmentDigest: the host, the toolchain the doctor reported
-- (without its coverage locations) and the build and lock files.
environmentDigest :: (Monad m) => String -> FilePath -> Json -> String -> Command m String
environmentDigest host root report language = do
  let toolchain = JString (compact (dropMember "coverage" report))
      (readable, compact') = templates language
  names <- sortBy compareUtf16 . filter (\n -> n `elem` environmentFiles || ".cabal" `isSuffixOf` n) . map entryName <$> listOrFail root
  files <- forM names $ \name -> do
    content <- fromUtf8 <$> readOrFail (join root name)
    pure [JString name, if Just content == M.lookup name compact' then maybe JNull JString (M.lookup name readable) else JString content]
  pure (sha (utf8 (compact (JArray ([JString host, toolchain] ++ concat files)))))

-- | recordedDigest: every recorded value under recorded/, by content; ""
-- when there are none.
recordedDigest :: (Monad m) => FilePath -> Command m String
recordedDigest folder = do
  grantRead [folder]
  parts <- walk ""
  pure (if null parts then "" else sha (B.concat parts))
  where
    walk rel = do
      listed <- effectOr (ListDirectory (if null rel then folder else join folder rel))
      let entries = either (const []) sortedEntries listed
      concat
        <$> forM
          entries
          ( \(Entry name kind) -> do
              let next = if null rel then name else rel ++ "/" ++ name
              case kind of
                SymbolicLinkKind -> failWith ("Recording input is a symbolic link: " ++ join folder next)
                DirectoryKind -> walk next
                FileKind -> do
                  content <- readOrFail (join folder next)
                  pure [utf8 (next ++ "\0"), content, utf8 "\0"]
                _ -> pure []
          )

-- | failure-database.mjs failureDatabase: the project's failure folder, its
-- database file and the database. An old database identified only the
-- language; its failures are copied once into the project's.
failureDatabase :: (Monad m) => FilePath -> String -> FilePath -> Command m (FilePath, FilePath, [(String, Json)])
failureDatabase configRoot language root = do
  let legacy = join configRoot (".lawspec/failures/" ++ language)
      directory = join legacy (projectKey root)
      file = join directory "laws.json"
  current <- readOptional file
  case current of
    Just text -> (\database -> (directory, file, database)) <$> parseDatabase text
    Nothing -> do
      old <- readOptional (join legacy "laws.json")
      database <- parseDatabase (fromMaybe "{}" old)
      effect (nodeFailure "mkdir" legacy) (MakeDirectories Nothing legacy)
      effect (nodeFailure "mkdir" directory) (MakeDirectories Nothing directory)
      forM_ ["inputs", "hypothesis", "proptest-regressions.txt"] $ \name ->
        copyTree (join legacy name) (join directory name)
      atomicWrite file (stringify (JObject database) ++ "\n") False
      text <- fromUtf8 <$> readOrFail file
      (\database' -> (directory, file, database')) <$> parseDatabase text
  where
    parseDatabase text = case parseJson text of
      Left problem -> failWith problem
      Right (JObject fields) -> pure fields
      Right _ -> failWith "The failure database must contain a map of law identities to failures"
    copyTree from to =
      effectOr (Stat NoFollow from) >>= \case
        Left problem
          | errorKind problem == NotFound -> pure ()
          | otherwise -> abort (nodeFailure "lstat" from problem)
        Right info -> case statusKind info of
          DirectoryKind -> do
            effect (nodeFailure "mkdir" to) (MakeDirectories Nothing to)
            entries <- listOrFail from
            forM_ entries $ \(Entry name _) -> copyTree (join from name) (join to name)
          FileKind -> readOrFail from >>= \bytes -> effect (nodeFailure "copyfile" to) (WriteFile Replace Nothing to bytes)
          _ -> pure ()

-- | harnessStatistics: the statistics a run wrote (LAWSPEC_STATS); a file
-- that is not JSON yet is skipped.
harnessStatistics :: (Monad m) => FilePath -> Command m [Json]
harnessStatistics directory = do
  names <- either (const []) (sortBy compareUtf16 . map entryName) <$> effectOr (ListDirectory directory)
  fmap concat . forM (filter (".json" `isSuffixOf`) names) $ \name ->
    effectOr (ReadFile (join directory name)) >>= \case
      Right bytes -> pure (either (const []) pure (parseJson (fromUtf8 bytes)))
      Left _ -> pure []

-- | The text of a file, or "" when it cannot be read.
readText :: (Monad m) => FilePath -> Command m String
readText file = either (const "") fromUtf8 <$> effectOr (ReadFile file)

-- | When a file was last modified, if it exists.
modified :: (Monad m) => FilePath -> Command m (Maybe Integer)
modified file = either (const Nothing) (Just . statusModified) <$> effectOr (Stat Follow file)

-- | The JUnit files a run wrote (report.files, or those of its directory
-- written since it started) and their texts.
junitTexts :: (Monad m) => FilePath -> Report -> Integer -> Command m [String]
junitTexts root report since = do
  files <- case report of
    JUnitFiles files -> pure files
    JUnitDirectory directory -> do
      let folder = join root directory
      names <- either (const []) (map entryName) <$> effectOr (ListDirectory folder)
      fmap concat . forM (filter (".xml" `isSuffixOf`) names) $ \name -> do
        info <- effect (nodeFailure "stat" (join folder name)) (Stat Follow (join folder name))
        pure [join folder name | statusModified info >= since]
    _ -> pure []
  fmap concat . forM files $ \file -> do
    let location = resolve root file
    time <- modified location
    case time of
      Just t | t >= since -> pure <$> readText location
      _ -> pure []

-- | executedTests: the tests a run executed, from its runner's report or
-- output.
executedTests :: (Monad m) => Maybe Report -> String -> FilePath -> Integer -> Command m [Json]
executedTests report output root since = case report of
  Just (NodeEvents file run) -> nodeEventTests run <$> readText (resolve root file)
  Just (BeamEvents file run) -> beamEventTests run <$> readText (resolve root file)
  Just (SwiftEvents files file run groups) -> do
    native <- junitTests <$> junitTexts root (JUnitFiles files) since
    raw <- readText (resolve root file)
    pure (swiftEventTests native run raw groups)
  Just r@(JUnitFiles _) -> junitTests <$> junitTexts root r since
  Just r@(JUnitDirectory _) -> junitTests <$> junitTexts root r since
  Just GoJson -> pure (goJsonTests output)
  Just RustLines -> pure (rustTests output)
  Just HspecLines -> pure (hspecTests output)
  Nothing -> pure []

-- | junitOf: a run's JUnit XML, the runner's own where it writes one,
-- otherwise made from what it printed. BEAM's intentional harness skips
-- stay reportable obligations.
junitOf :: (Monad m) => FilePath -> NativeRun -> [Json] -> Integer -> Command m String
junitOf root run executed since = case runReport run of
  Just report@(JUnitFiles _) -> joinLines <$> junitTexts' report
  Just report@(JUnitDirectory _) -> joinLines <$> junitTexts' report
  other -> do
    let skipped = case other of
          Just (BeamEvents _ _) ->
            [ jsObject
                ( [("name", v) | Just v <- [member "label" entry]]
                    ++ [("classname", v) | Just v <- [member "unit" entry]]
                    ++ [("status", JString "skipped")]
                    ++ [("reason", v) | Just v <- [member "skip" entry]]
                )
            | entry <- runLaws run,
              maybe False isTruthy (member "skip" entry)
            ]
          _ -> []
    pure (junitFromTests (executed ++ skipped))
  where
    joinLines [] = ""
    joinLines items = foldr1 (\a b -> a ++ "\n" ++ b) items
    junitTexts' report = do
      files <- case report of
        JUnitFiles files -> pure files
        JUnitDirectory directory -> do
          let folder = join root directory
          names <- either (const []) (map entryName) <$> effectOr (ListDirectory folder)
          pure [join folder name | name <- names, ".xml" `isSuffixOf` name]
        _ -> pure []
      fmap concat . forM files $ \file -> do
        let location = resolve root file
        time <- modified location
        case time of
          Just t | t >= since -> pure <$> (fromUtf8 <$> readOrFail location)
          _ -> pure []

-- | The tool --coverage needs on a target, if it is missing.
coverageMissing :: (Monad m) => Json -> FilePath -> Json -> Command m (Maybe (String, String))
coverageMissing target root report = case coverageTool language of
  Nothing -> pure (Just ("a coverage tool", "no coverage tool is known for this target"))
  Just (tool, check, install) -> do
    let missing ok = if ok then Nothing else Just (tool, install)
    case language of
      _
        | language `elem` ["erlang", "elixir", "gleam"] -> case beamCoverageRequirement target report of
            Just requirement -> pure (Just requirement)
            Nothing -> missing <$> probe "erl" ["-noshell", "-eval", "case code:ensure_loaded(cover) of {module,cover} -> halt(0); _ -> halt(1) end."]
      "python" -> missing <$> probe (setting "python" "python3") (fromMaybe [] check)
      _ | language `elem` ["javascript", "typescript"] -> missing <$> probe "npx" ["--no-install", "c8", "--version"]
      "rust" -> missing <$> probe "cargo" ["llvm-cov", "--version"]
      "kotlin" -> do
        let file = join root "build.gradle.kts"
        content <- readText file
        pure (missing (isInfix "kover" content))
      _ -> pure Nothing
  where
    language = maybe "" jsString (member "language" target)
    setting key fallback = case member key target of
      Just value | isTruthy value -> jsString value
      _ -> fallback
    probe command arguments = do
      ran <- runProcess (launch command arguments root)
      pure (isNothing (runError ran) && runExit ran == Just (ExitCode 0))
    isInfix needle haystack = any (needle `isPrefixOf`) (suffixesOf haystack)
    suffixesOf s = case s of
      [] -> [[]]
      _ : more -> s : suffixesOf more

-- | The session's state for one run of lawspec test: what spawned() shows
-- runs through these.
data Settings = Settings
  { settingJson :: Bool,
    settingRoot :: FilePath
  }

-- | spawned(): run a native command, showing its output (on standard error
-- with --json) and keeping it, both streams in the order they arrived. Go's
-- JSON events are shown as the text they carry. A command that cannot
-- start fails the command, as the rejected promise did.
spawned :: (Monad m) => Settings -> String -> [String] -> [(String, Maybe String)] -> Bool -> Command m (Bool, String)
spawned settings command arguments variables goJson = do
  let shown = if settingJson settings then Stderr else Stdout
  ran <-
    runProcess
      (launch command arguments (settingRoot settings))
        { launchEnvironment = variables,
          launchEcho = if goJson then EchoGoJson shown else EchoTo shown
        }
  forM_ (runError ran) failWith
  pure (runExit ran == Just (ExitCode 0), fromUtf8 (runCombined ran))

-- | Today's time as toISOString.
now :: (Monad m) => Command m (Integer, String)
now = do
  clock <- effect (\problem -> Failure (errorMessage problem) Nothing) GetClock
  pure (wallMilliseconds clock, isoTime (wallMilliseconds clock))

-- | A fresh seed: 1 + Math.floor(Math.random() * 2147483646), from the
-- host's clock.
freshSeed :: (Monad m) => Command m String
freshSeed = do
  token <- freshToken "seed"
  let value = foldl (\n c -> n * 16 + toInteger (fromMaybe 0 (lookup c (zip "0123456789abcdef" [0 :: Int ..])))) 0 (take 12 (filter (/= '-') token))
  pure (show (1 + value `mod` 2147483646))

-- | The node JavaScript tests run with: the PATH's, by its real path, as
-- process.execPath names the node that ran the legacy CLI.
nodeExecutable :: (Monad m) => FilePath -> Command m FilePath
nodeExecutable root = do
  found <- resolveTool root Nothing "node"
  case found of
    Left _ -> pure "node"
    Right file -> either (const file) id <$> effectOr (RealPath file)

-- | navigator.hardwareConcurrency: the processors online, as getconf
-- reports them.
processors :: (Monad m) => FilePath -> Command m (Maybe Int)
processors root = do
  ran <- runProcess (launch "getconf" ["_NPROCESSORS_ONLN"] root)
  pure $ case reads (fromUtf8 (runStdout ran)) of
    [(n, rest)] | runSucceeded ran, all (`elem` (" \n" :: String)) rest, n > 0 -> Just n
    _ -> Nothing

-- | lawspec test, after the compile input is built: run each selected
-- target's laws, print the summary and return the exit code (1 when a
-- target failed, 2 when a law was vacuous).
runTests :: (Monad m) => Invocation -> Arguments -> Json -> Json -> [(Json, FilePath)] -> FilePath -> Command m Int
runTests invocation arguments config input selected configRoot = do
  let cwd = invocationDirectory invocation
      json = flag "json" arguments
  seed <- maybe freshSeed pure (option "seed" arguments)
  offline <- (== Right (Just "1")) <$> effectOr (GetEnvironment "LAWSPEC_OFFLINE")
  report <- case option "report" arguments of
    Nothing -> pure Nothing
    Just value -> case stripPrefix "junit=" value of
      Just file@(_ : _) | '\n' `notElem` file && '\r' `notElem` file -> pure (Just file)
      _ -> failWith "--report takes junit=<path>"
  attestation <- readAttestation arguments config configRoot cwd
  grantRead (map snd selected)
  (summaries, junit) <-
    foldM
      ( \(summaries, junit) (target, root) -> do
          (summary, more) <- runTarget (Settings json root) seed offline attestation (isJust report) target root
          pure (summaries ++ [summary], junit ++ more)
      )
      ([], [])
      selected
  forM_ report $ \file -> do
    let location = resolve cwd file
        parent = takeDirectory location
    grantWrite [location]
    -- Reading the parent is granted first: a denied stat would read as a
    -- missing directory, and creating it would make a directory that may
    -- contain the project a write root, which the guard refuses.
    grantRead [parent]
    exists <-either (const False) ((== DirectoryKind) . statusKind) <$> effectOr (Stat Follow parent)
    unless exists $ do
      grantWrite [parent]
      effect (nodeFailure "mkdir" parent) (MakeDirectories Nothing parent)
    effect (nodeFailure "open" location) (WriteFile Replace Nothing location (utf8 (mergeJunit junit)))
  if json
    then printJson (JArray summaries)
    else printLine (joinWith "\n" (map (summaryText summaries) summaries))
  pure $
    if any ((/= Just (JBool True)) . member "ok") summaries
      then 1
      else if any (isJust . member "vacuous") summaries then 2 else 0
  where
    joinWith _ [] = ""
    joinWith separator items = foldr1 (\a b -> a ++ separator ++ b) items
    stripPrefix prefix text = if prefix `isPrefixOf` text then Just (drop (length prefix) text) else Nothing
    runTarget settings seed offline attestation reporting target root = do
      let language = maybe "" jsString (member "language" target)
          has key = present key arguments
          json = flag "json" arguments
          minify = flag "minify" arguments
          build = buildDigest invocation
          host = hostIdentity (invocationHost invocation) build
          recordedFolder = join configRoot "recorded"
          updateRecorded = flag "update-recorded" arguments
          tagsOf key = M.findWithDefault [] key (lists arguments)
          explicitSeed = option "seed" arguments
          cwd = invocationDirectory invocation
      let targetFields' =
            ("target", fromMaybe JNull (member "language" target))
              : [(key, value) | key <- ["sourceDir", "testDir", "generatedSourceDir", "generatedTestDir", "release", "nativeBindings", "actors"], Just value <- [member key target]]
      planned <-
        call "planGeneration" (jsObject (members input ++ targetFields' ++ [("minify", JBool minify)] ++ [("attestation", a) | Just a <- [attestation]]))
          >>= diagnostics json
      seedJson <- either failWith pure (nativeSeed (JString seed))
      let tests = fromMaybe [] (member "tests" planned >>= arrayOf)
          files = fromMaybe [] (member "files" planned >>= arrayOf)
          attested = attestedKeys planned
      if null tests && not (has "benchmarks")
        then
          pure
            ( jsObject
                ( [("target", JString language)]
                    ++ [("root", v) | Just v <- [member "root" target]]
                    ++ [ ("seed", seedJson),
                         ("ran", JArray []),
                         ("unchanged", integer 0),
                         ("ok", JBool True),
                         ("testsExecuted", integer 0),
                         ("selection", JString "no-selected-native-checks")
                       ]
                ),
              []
            )
        else do
          let mutated = [resolve cwd name | name <- splitComma (fromMaybe "" (option "mutated-generated" arguments)), not (null name)]
          pending <- planWrites root (artifactsFrom (JArray files)) ".lawspec/generated.json" (\file -> resolve cwd file `elem` mutated)
          unless (null (planChanges pending)) $
            failWith (language ++ ": generated files are out of date; run lawspec generate" ++ (if minify then " --minify" else ""))
          forM_ (configurationInvocations target) $ \(command, arguments') -> do
            (ok, _) <- spawned settings command arguments' [] False
            unless ok (failWith (language ++ ": native build metadata preparation failed"))
          doctorReport <- doctor target root files
          unless (member "ok" doctorReport == Just (JBool True)) $
            failWith (language ++ ": " ++ textOf "message" doctorReport ++ "\n" ++ textOf "instructions" doctorReport)
          let generated = [path | file <- files, member "ownership" file == Just (JString "generated"), Just (JString path) <- [member "path" file]]
          environment <- environmentDigest host root doctorReport language
          recorded <- recordedDigest recordedFolder
          project <- projectDigest root generated language configRoot (fromMaybe (JArray []) (member "inputs" config))
          let machineBits = fromMaybe JNull (member "machineBits" input)
              keys = lawKeys build target machineBits tests environment project recorded attested
              identity = projectKey root
              resultsFile = join configRoot (".lawspec/results/" ++ language ++ "-" ++ identity ++ ".json")
          grantRead [resultsFile]
          previous <- readOptional resultsFile >>= either failWith pure . parseJson . fromMaybe "{\"version\":1,\"laws\":{}}"
          presentationEnvironment <- environmentDigest host root doctorReport language
          let presentation = presentationDigest files presentationEnvironment
              previousLaws = maybe [] members (member "laws" previous)
          when (member "presentation" previous /= Just (JString presentation)) $ do
            let checks = presentationInvocations target files offline
            when (null checks) (failWith (language ++ ": no native source validator is available"))
            forM_ checks $ \(command, arguments', variables) -> do
              (ok, output) <- spawned settings command arguments' variables False
              unless ok . failWith $
                if language == "go" && newBound output && "redeclared in this block" `isInfixOf'` output
                  then "Go handler bridge conflicts with an existing New<Ability>Bound workaround. Remove or rename that manual wrapper; user-owned adapters have been preserved."
                  else language ++ ": current generated source failed native validation"
          (failures, databaseFile, database) <- failureDatabase configRoot language root
          let chosen = selectByTags tests (tagsOf "tag") (tagsOf "exclude-tag")
              stale = testsToRun chosen keys previousLaws database (has "fresh" || has "coverage" || updateRecorded)
          batches <- either failWith pure (planBatches stale database seed (isNothing explicitSeed))
          let profile =
                JObject
                  [ ("target", JString language),
                    ("root", JString root),
                    ("machineBits", machineBits),
                    ("minify", JBool minify),
                    ("build", JString build)
                  ]
              settingsFor batchSeed' output' ok' at started =
                Attempt keys batchSeed' ok' profile output' tests at started
          (_, at0) <- now
          attempts0 <-
            foldM
              ( \kept batch -> do
                  batchSeed' <- either failWith pure (nativeSeed (JString (batchSeed batch)))
                  pure (assign kept (recordNativeAttempts (batchEntries batch) Nothing JNull [] (settingsFor batchSeed' "" False at0 False)))
              )
              (maybe [] members (member "attempts" previous))
              batches
          let pendingLaws = [(law, result) | (law, result) <- previousLaws, law `notElem` map lawId stale]
              resultsFolder = takeDirectory resultsFile
              writePending attempts =
                atomicWrite resultsFile (stringify (jsObject (members previous ++ [("version", integer 1), ("laws", JObject pendingLaws), ("attempts", JObject attempts)])) ++ "\n") False
          effect (nodeFailure "mkdir" resultsFolder) (MakeDirectories Nothing resultsFolder)
          effect (nodeFailure "open" (join resultsFolder ".gitignore")) (WriteFile Replace Nothing (join resultsFolder ".gitignore") (utf8 "*\n"))
          writePending attempts0
          let scratch = join configRoot (".lawspec/reports/" ++ language ++ "/" ++ identity)
              stats = join scratch "statistics"
              beam = language `elem` ["erlang", "elixir", "gleam"]
              coverage = if has "coverage" then Just (join configRoot (".lawspec/coverage/" ++ language ++ "/" ++ identity)) else Nothing
          removeIfPresent scratch
          effect (nodeFailure "mkdir" stats) (MakeDirectories Nothing stats)
          effect (nodeFailure "mkdir" failures) (MakeDirectories Nothing failures)
          effect (nodeFailure "open" (join configRoot ".lawspec/reports/.gitignore")) (WriteFile Replace Nothing (join configRoot ".lawspec/reports/.gitignore") (utf8 "*\n"))
          missingCoverage <- maybe (pure Nothing) (const (coverageMissing target root doctorReport)) coverage
          let useCoverage = if isJust missingCoverage then Nothing else coverage
          forM_ missingCoverage $ \(tool, install) ->
            printError (language ++ ": --coverage needs " ++ tool ++ ", which is not available; " ++ install ++ ". Running without coverage.")
          forM_ useCoverage $ \folder -> do
            when (beam || language == "scala") (removeIfPresent folder)
            let made = if beam then join folder "runs" else folder
            effect (nodeFailure "mkdir" made) (MakeDirectories Nothing made)
          xdist <-
            if language == "python" && any (truthy "parallel") stale
              then do
                ran <- runProcess (launch (setting target "python" "python3") ["-c", "import xdist"] root)
                pure (runExit ran == Just (ExitCode 0))
              else pure False
          let expected entry = not (truthy "skip" entry) && (not (truthy "knownDiscrepancy" entry) || beam)
              benchmarking = if has "benchmarks" then fromMaybe [] (member "benchmarks" planned >>= arrayOf) else []
          node <- if language `elem` ["javascript", "typescript"] then nodeExecutable root else pure "node"
          cpus <- if language `elem` ["javascript", "typescript"] && any (truthy "parallel") stale then processors root else pure Nothing
          unless (null batches && null benchmarking) $
            forM_ (preparationInvocations target files) $ \(command, arguments') -> do
              (ok, _) <- spawned settings command arguments' [] False
              unless ok (failWith (language ++ ": native test preparation failed"))
          let baseVariables batchSeed' =
                [ ("LAWSPEC_SEED", Just batchSeed'),
                  ("HSPEC_SEED", Just batchSeed'),
                  ("LAWSPEC_STATS", Just stats),
                  ("LAWSPEC_FAILURES", Just failures),
                  ("LAWSPEC_FOUND", Just (join configRoot ".lawspec/found")),
                  ("LAWSPEC_RECORDED", Just recordedFolder)
                ]
                  ++ [("LAWSPEC_UPDATE_RECORDED", Just "1") | updateRecorded]
          -- The batches, in order, until one that could not start stops the run.
          let runBatches state [] = pure state
              runBatches state (batch : later) = do
                batchSeed' <- either failWith pure (nativeSeed (JString (batchSeed batch)))
                (_, at) <- now
                let attempts1 = assign (stAttempts state) (recordNativeAttempts (batchEntries batch) Nothing JNull [] (settingsFor batchSeed' "" False at True))
                writePending attempts1
                token <- freshToken ("test " ++ language ++ " " ++ batchSeed batch)
                runs <-
                  either failWith pure $
                    nativeInvocations
                      target
                      (batchEntries batch)
                      (RunOptions offline scratch useCoverage xdist root (member "coverage" doctorReport) node cpus token)
                (state', progress) <- runInvocations batch batchSeed' (state {stAttempts = attempts1}, startBatch) runs
                if continueRun progress then runBatches state' later else pure state'
              runInvocations _ _ result [] = pure result
              runInvocations batch batchSeed' (state, progress) (run : rest) = do
                (since, _) <- now
                (ok, output) <- spawned settings (runProgram run) (runArguments run) (runVariables run ++ baseVariables (batchSeed batch)) (runReport run == Just GoJson)
                when (not ok && language == "scala" && isScalaCompilationFailure output) $ do
                  captured <- captureScalaBuildFailure root (runProgram run) (runArguments run) output
                  forM_ captured $ \directory -> printError ("Scala compiler state: " ++ directory)
                executed <- executedTests (runReport run) output root since
                (_, at) <- now
                let observed = recordNativeAttempts (runLaws run) (runMatches run) (JString (runProgram run)) executed (settingsFor batchSeed' output ok at True)
                    attemptsAfter =
                      assign
                        ( if not ok && null (runLaws run)
                            then assign (stAttempts state) (recordNativeAttempts (batchEntries batch) Nothing (JString (runProgram run)) [] (settingsFor batchSeed' output False at True))
                            else stAttempts state
                        )
                        observed
                    outcomeOf entry = lookup (lawId entry) observed >>= member "outcome"
                    passedNow = [entry | entry <- runLaws run, outcomeOf entry `elem` map (Just . JString) ["passed", "known-discrepancy"] || not (expected entry)]
                    passed' = stPassed state ++ passedNow
                junit' <-
                  if reporting
                    then do
                      xml <- junitOf root run executed since
                      pure (stJunit state ++ [(language ++ " (" ++ maybe "undefined" jsString (member "root" target) ++ ")", xml)])
                    else pure (stJunit state)
                let lawTests = length [() | test <- executed, Just match <- [runMatches run], not (null (match test))]
                    (progress', invocationFailed, continueBatch) = afterInvocation progress ok executed lawTests
                    state' =
                      state
                        { stAttempts = attemptsAfter,
                          stSeedOf = assignSeeds (stSeedOf state) [(lawId entry, batchSeed batch) | entry <- runLaws run],
                          stPassed = passed',
                          stJunit = junit',
                          stCoverageRuns = stCoverageRuns state ++ [c | Just c <- [runCoverage run]]
                        }
                if invocationFailed
                  then
                    if continueBatch
                      then runInvocations batch batchSeed' (state' {stFailed = True}, progress') rest
                      else pure (state' {stFailed = True}, progress')
                  else
                    runInvocations
                      batch
                      batchSeed'
                      ( state' {stUnrun = stUnrun state' ++ [entry | entry <- runLaws run, lawId entry `notElem` map lawId passed', expected entry]},
                        progress'
                      )
                      rest
          state <- runBatches (Running attempts0 [] [] False [] [] []) batches
          let failed0 = stFailed state || not (null (stUnrun state))
          (failed1, coverageWritten1, coverageError1) <-
            case useCoverage of
              Just folder
                | language == "scala" && not failed0 ->
                    recover ((\written -> (failed0, written, Nothing)) <$> collectScalaCoverage root folder (setting target "scala" "scala") offline) (\problem -> pure (True, False, Just (failureMessage problem)))
              _ -> pure (failed0, False, Nothing)
          (failed, coverageWritten, coverageError) <-
            case useCoverage of
              Just folder
                | beam ->
                    recover ((\written -> (failed1, isJust written, coverageError1)) <$> collectBeamCoverage root folder (stCoverageRuns state)) (\problem -> pure (True, False, Just (failureMessage problem)))
              _ -> pure (failed1, coverageWritten1, coverageError1)
          -- --benchmarks: measured, never asserted, and never cached.
          benchmarksFailed <-
            if failed
              then pure False
              else do
                runs <- either failWith pure (benchmarkInvocations target benchmarking offline node)
                foldM
                  ( \stopped (command, arguments', variables) ->
                      if stopped
                        then pure True
                        else do
                          (ok, _) <-
                            spawned
                              settings
                              command
                              arguments'
                              ( variables
                                  ++ [ ("LAWSPEC_SEED", Just seed),
                                       ("HSPEC_SEED", Just seed),
                                       ("LAWSPEC_STATS", Just stats),
                                       ("LAWSPEC_FOUND", Just (join configRoot ".lawspec/found")),
                                       ("LAWSPEC_RECORDED", Just recordedFolder)
                                     ]
                              )
                              False
                          pure (not ok)
                  )
                  False
                  runs
          let failedAll = failed || benchmarksFailed
          statistics <- harnessStatistics stats
          let passed = stPassed state
              passedLaws = map lawId passed
              kept entry = case lookup (lawId entry) previousLaws of
                Just result | result /= JNull -> Just result
                _ -> previousResult previousLaws (lawId entry) (M.lookup (lawId entry) keys)
              laws0 = [(lawId entry, result) | entry <- tests, Just result <- [kept entry]]
              attemptsBefore = stAttempts state
          lawsPassed <-
            foldM
              ( \acc entry -> do
                  (_, at) <- now
                  seedValue <- either failWith pure (nativeSeed (JString (fromMaybe seed (lookup (lawId entry) (stSeedOf state)))))
                  let label = member "label" entry
                      observed = [s | s <- statistics, member "law" s == label]
                      adequate s = any (\key -> maybe False isTruthy (member key s)) ["cover", "labels", "classes"]
                      result =
                        jsObject
                          ( [("key", JString k) | Just k <- [M.lookup (lawId entry) keys]]
                              ++ [("seed", seedValue), ("passed", JString at)]
                              ++ [("environment", runId a) | Just a <- [attestation], isJust (lookup (lawId entry) attested)]
                              ++ [("flaky", JBool True) | any ((== Just (JString "flaky")) . member "outcome") observed]
                              ++ [ ( "adequacy",
                                     JArray
                                       [ jsObject [(key, v) | key <- ["test", "cases", "cover", "classes", "labels"], Just v <- [member key s]]
                                       | s <- observed,
                                         adequate s
                                       ]
                                   )
                                 | any adequate observed
                                 ]
                          )
                  pure (assign acc [(lawId entry, result)])
              )
              laws0
              passed
          let (attemptsReached, vacuous) = applyReach attemptsBefore [entry | entry <- stale, lawId entry `elem` passedLaws] statistics
              vacuousLaws = map lawId vacuous
              lawsWithReach =
                foldl
                  ( \acc entry -> case (lookup (lawId entry) acc, lookup (lawId entry) attemptsReached >>= member "reach") of
                      (Just result, Just reach) | isTruthy result -> assign acc [(lawId entry, setMember "reach" reach result)]
                      _ -> acc
                  )
                  (filter ((`notElem` vacuousLaws) . fst) lawsPassed)
                  passed
              reachLines = concat [reachText entry (lookup (lawId entry) attemptsReached) | entry <- stale]
              laws = filter (\(law, _) -> law `notElem` [lawId entry | entry <- stale, lawId entry `notElem` passedLaws]) lawsWithReach
          (_, failedAt) <- now
          let recorded' = recordFailures database stale passedLaws attemptsReached failedAt
          effect (nodeFailure "open" (join configRoot ".lawspec/failures/.gitignore")) (WriteFile Replace Nothing (join configRoot ".lawspec/failures/.gitignore") (utf8 "*\n"))
          effect (nodeFailure "open" databaseFile) (WriteFile Replace Nothing databaseFile (utf8 (stringify (JObject recorded') ++ "\n")))
          effect (nodeFailure "mkdir" resultsFolder) (MakeDirectories Nothing resultsFolder)
          effect (nodeFailure "open" (join resultsFolder ".gitignore")) (WriteFile Replace Nothing (join resultsFolder ".gitignore") (utf8 "*\n"))
          let attempts = case attestation of
                Nothing -> attemptsReached
                Just a ->
                  foldl
                    ( \acc entry -> case lookup (lawId entry) acc of
                        Just attempt
                          | isJust (lookup (lawId entry) (stSeedOf state)) ->
                              assign acc [(lawId entry, JObject (assign (members attempt) ([("executionRun", runId a)] ++ [("environment", runId a) | isJust (lookup (lawId entry) attested)])))]
                        _ -> acc
                    )
                    attemptsReached
                    stale
              candidates = assign (maybe [] members (member "attestations" previous)) [(jsString (runId a), a) | Just a <- [attestation]]
              referenced identifier = any (\run -> member "environment" run == Just (JString identifier) || member "executionRun" run == Just (JString identifier)) (map snd laws ++ map snd attempts)
              attestations = [(identifier, value) | (identifier, value) <- candidates, referenced identifier]
          atomicWrite
            resultsFile
            ( stringify
                ( JObject
                    ( [("version", integer 1), ("laws", JObject laws), ("attempts", JObject attempts), ("presentation", JString presentation)]
                        ++ [("attestations", JObject attestations) | not (null attestations)]
                    )
                )
                ++ "\n"
            )
            False
          let flaky = nub [fromMaybe JNull (member "law" s) | s <- statistics, member "outcome" s == Just (JString "flaky")]
              unmet =
                [ maybe "undefined" jsString (member "law" s) ++ ": cover " ++ field "required" c ++ "% \"" ++ field "label" c ++ "\" (" ++ field "observed" c ++ "%)"
                | s <- statistics,
                  Just (JArray covers) <- [entryField "cover" s],
                  c <- covers,
                  not (maybe False isTruthy (member "met" c))
                ]
              benchmarks = [s | s <- statistics, maybe False isTruthy (member "benchmark" s)]
              parallelism = [jsObject ([("unit", v) | Just v <- [member "parallel" s]] ++ [(key, v) | key <- ["mode", "workers"], Just v <- [member key s]]) | s <- statistics, maybe False isTruthy (member "parallel" s)]
          batchRows <-
            forM (batchSummaries batches attempts) $ \row -> do
              seedValue <- either failWith pure (nativeSeed (fromMaybe JNull (member "seed" row)))
              pure (setMember "seed" seedValue row)
          let notRun = concat [items | row <- batchRows, Just (JArray items) <- [member "notRun" row]]
              unrun = stUnrun state
              failedLaws =
                [ JString (lawId entry)
                | entry <- stale,
                  Just attempt <- [lookup (lawId entry) attempts],
                  member "outcome" attempt == Just (JString "failed"),
                  maybe 1 length (member "check" attempt >>= member "nativeGroup" >>= arrayOf) == 1,
                  any ((== Just (JString "failed")) . member "status") (fromMaybe [] (member "tests" attempt >>= arrayOf))
                ]
          pure
            ( jsObject
                ( [("target", JString language)]
                    ++ [("root", v) | Just v <- [member "root" target]]
                    ++ [ ("seed", seedJson),
                         ("ran", JArray [JString (lawId entry) | entry <- stale, JString (lawId entry) `notElem` notRun]),
                         ("batches", JArray batchRows)
                       ]
                    ++ [("notRun", JArray notRun) | not (null notRun)]
                    ++ [("environment", v) | Just a <- [attestation], Just v <- [member "environment" a]]
                    ++ [ ("unchanged", integer (fromIntegral (length chosen - length stale))),
                         ("ok", JBool (not failedAll)),
                         ("failedLaws", JArray failedLaws)
                       ]
                    ++ [("deselected", integer (fromIntegral (length tests - length chosen))) | length chosen /= length tests]
                    ++ [("unrun", JArray [JString (lawId entry) | entry <- unrun]) | not (null unrun)]
                    ++ [("flaky", JArray flaky) | not (null flaky)]
                    ++ [("unmetCover", JArray (map JString unmet)) | not (null unmet)]
                    ++ [("vacuous", JArray (map JString vacuousLaws)) | not (null vacuous)]
                    ++ [("reach", JArray (map JString reachLines)) | not (null reachLines)]
                    ++ [("benchmarks", JArray benchmarks) | not (null benchmarks)]
                    ++ [("parallelism", JArray parallelism) | not (null parallelism)]
                    ++ [("coverageError", JString e) | Just e <- [coverageError]]
                    ++ [ ("coverage", JString (let r = relative cwd folder in if null r then "." else r))
                       | Just folder <- [useCoverage],
                         (not beam && language /= "scala") || coverageWritten
                       ]
                ),
              stJunit state
            )
    textOf key value = maybe "undefined" jsString (member key value)
    field key value = maybe "undefined" jsString (member key value)
    truthy key entry = maybe False isTruthy (member key entry)
    setting target key fallback = case member key target of
      Just value | isTruthy value -> jsString value
      _ -> fallback
    runId a = fromMaybe JNull (member "run" a >>= member "id")
    splitComma value = case break (== ',') value of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitComma rest
    newBound output = any (\rest -> "New" `isPrefixOf` rest && boundAfter (drop 3 rest)) (suffixesOf output)
    boundAfter rest = case span wordChar' rest of
      (_ : _, _) -> any (\k -> "Bound" `isPrefixOf` drop k rest && k >= 1) [1 .. length (takeWhile wordChar' rest)]
      _ -> False
    wordChar' c = c `elem` (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ "_")
    isInfixOf' needle haystack = any (needle `isPrefixOf`) (suffixesOf haystack)
    suffixesOf s = case s of
      [] -> [[]]
      _ : more -> s : suffixesOf more
    assignSeeds kept new = foldl (\acc (law, s) -> (law, s) : filter ((/= law) . fst) acc) kept new
    removeIfPresent folder =
      effectOr (Remove Recursive folder) >>= \case
        Left problem | errorKind problem /= NotFound -> abort (nodeFailure "rm" folder problem)
        _ -> pure ()

-- | What the batches of one target have shown so far.
data Running = Running
  { stAttempts :: [(String, Json)],
    stPassed :: [Json],
    stUnrun :: [Json],
    stFailed :: Bool,
    stSeedOf :: [(String, String)],
    stJunit :: [(String, String)],
    stCoverageRuns :: [Json]
  }

-- | readAttestation: the environment attestation --attestation or
-- lawspec.edn names, if any.
readAttestation :: (Monad m) => Arguments -> Json -> FilePath -> FilePath -> Command m (Maybe Json)
readAttestation arguments config configRoot cwd = do
  let file = case option "attestation" arguments of
        Just named -> Just (resolve cwd named)
        Nothing -> resolve configRoot . jsString <$> member "attestation" config
  case file of
    Nothing -> pure Nothing
    Just path' -> do
      grantRead [path']
      content <- readOptional path'
      case content of
        Nothing -> failWith ("No environment attestation at " ++ path')
        Just text -> case parseJson text of
          Right value -> pure (Just value)
          Left problem -> failWith (path' ++ ": the environment attestation is not JSON: " ++ problem)

-- | One summary as the text output shows it.
summaryText :: [Json] -> Json -> String
summaryText summaries s =
  target
    ++ (if length [() | other <- summaries, member "target" other == member "target" s] > 1 then " (" ++ maybe "undefined" jsString (member "root" s) ++ ")" else "")
    ++ ": "
    ++ ( if not (null ran) || isJust (member "notRun" s)
           then ranText (list "batches") ++ maybe "" (\e -> " in environment " ++ jsString e) (truthyMember "environment")
           else "nothing to run"
       )
    ++ ( if member "selection" s == Just (JString "no-selected-native-checks")
           then "; no native checks selected; intrinsic definition checks passed."
           else ", " ++ field "unchanged" ++ " unchanged since their last passing run." ++ (if member "ok" s == Just (JBool True) then "" else " FAILED")
       )
    ++ maybe "" (\d -> "\n" ++ jsString d ++ " law(s) not selected by --tag or --exclude-tag.") (truthyMember "deselected")
    ++ maybe "" (\n -> "\nNot run: " ++ joinComma (map jsString (items n)) ++ "; an earlier native invocation failed before any test executed.") (truthyMember "notRun")
    ++ maybe "" (\u -> "\nNo tests ran for " ++ joinComma (map jsString (items u)) ++ "; the runner matched none of their tests.") (truthyMember "unrun")
    ++ maybe "" (\f -> "\nFlaky (failed, then passed on a retry): " ++ joinComma (map jsString (items f))) (truthyMember "flaky")
    ++ maybe "" (\u -> "\nCover not met: " ++ joinWith "; " (map jsString (items u))) (truthyMember "unmetCover")
    ++ maybe "" (\r -> "\nGuarded laws:\n" ++ joinWith "\n" (map jsString (items r))) (truthyMember "reach")
    ++ maybe "" (\v -> "\n" ++ show (length (items v)) ++ " law(s) VACUOUS: no generated case reached the guarded consequence, so the run is incomplete.") (truthyMember "vacuous")
    ++ maybe "" (\p -> "\n" ++ joinWith "\n" ["parallel " ++ shown "unit" x ++ ": " ++ shown "mode" x ++ ", " ++ shown "workers" x ++ " worker(s)" | x <- items p]) (truthyMember "parallelism")
    ++ maybe
      ""
      ( \b ->
          "\n"
            ++ joinWith
              "\n"
              [ "benchmark " ++ shown "benchmark" x ++ ": mean " ++ toFixed 2 (meanNs x / 1000) ++ " us over " ++ shown "iterations" x ++ " iteration(s)"
              | x <- items b
              ]
      )
      (truthyMember "benchmarks")
    ++ maybe "" (\e -> "\nCoverage failed: " ++ jsString e) (truthyMember "coverageError")
    ++ maybe "" (\c -> "\nCoverage written to " ++ jsString c ++ ".") (truthyMember "coverage")
  where
    target = maybe "undefined" jsString (member "target" s)
    ran = fromMaybe [] (member "ran" s >>= arrayOf)
    list key = fromMaybe [] (member key s >>= arrayOf)
    items value = fromMaybe [] (arrayOf value)
    truthyMember key = case member key s of
      Just value | isTruthy value -> Just value
      _ -> Nothing
    field key = maybe "undefined" jsString (member key s)
    shown key x = maybe "undefined" jsString (member key x)
    meanNs x = case member "mean_ns" x of
      Just (JNumber n) -> toRealFloat n
      Just (JString t) -> maybe (0 / 0) (\case JNumber n -> toRealFloat n; _ -> 0 / 0) (jsNumber t)
      Just JNull -> 0
      Just (JBool b) -> if b then 1 else 0
      _ -> 0 / 0
    joinComma = joinWith ", "
    joinWith _ [] = ""
    joinWith separator xs = foldr1 (\a b -> a ++ separator ++ b) xs
