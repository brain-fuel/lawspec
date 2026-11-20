-- | The Node CLI's main(), ported: the option checks every command makes, in
-- their order and with their texts, then the command. A command, or a case
-- of one, that is not ported stops with 'unported' before anything is
-- written or printed; the checks before it are the Node CLI's own, so an
-- invocation either fails here exactly as it would there or reaches the
-- legacy CLI unchanged.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Cli
  ( cli,
    usageText,
    reportFailure,
    subcommand,
  )
where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Trans.Except (catchE, throwE)
import qualified Data.ByteString as B
import Data.Char (isDigit)
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Set as S
import Data.Version (showVersion)
import LawSpec.App.Advice (authoringReport, printAdvice)
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Describe (describeComponent)
import LawSpec.App.Doctor (doctor, doctorCommand)
import LawSpec.App.Evidence (Observing (..), attachNativeEvidence, evidenceCommand, evidenceStatuses, readNativeObservations)
import LawSpec.App.Examples (examplesCommand)
import LawSpec.App.Files
import LawSpec.App.Format (FormatOptions (..), formatCommand)
import LawSpec.App.Init (initCommand)
import LawSpec.App.Json
import LawSpec.App.Learn (learnCommand)
import LawSpec.App.Reference (referenceCommand)
import LawSpec.App.Lsp (lspCommand)
import LawSpec.App.Mcp (mcpCommand)
import LawSpec.App.Mutate (mutateCommand)
import LawSpec.App.PackageCommands (fetchCommand, packageCommand)
import LawSpec.App.Packages
import LawSpec.App.Project
import LawSpec.App.ProjectCommand (projectCommand)
import LawSpec.App.Prove (proveCommand)
import LawSpec.App.Test (readAttestation, runTests)
import LawSpec.App.TestResults (hostIdentity)
import LawSpec.Host.Effect (Clock (..), Effect (..), EntryKind (..), Follow (..), HostError (..), Status (..), Stream (..))
import LawSpec.Host.Path (join, resolve, takeDirectory)
import LawSpec.Host.Sandbox (closed)
import LawSpec.Scaffold (testCommand)
import LawSpec.Targets (artifactTargets, programTargets, targets)
import Paths_lawspec (version)

usageText :: String
usageText =
  "LawSpec "
    ++ showVersion version
    ++ "\nUsage: lawspec prelude [query] [--json]\n       lawspec inspect --target <target> [--json]\n       lawspec advise [--target <target>] [--json] [--strict]\n       lawspec project init|adopt|status|validate [--project <directory>]\n       lawspec learn [--port <port>]\n       lawspec reference [<name>]\n       lawspec init --target <language> [--project <directory>] [--name <name>] [--group <id>] [--minify] [--no-install]\n       lawspec init --target java [--release 21|25] [--generated-source-dir <directory>] [--generated-test-dir <directory>]\n       lawspec fmt [paths...] [--check] [--compile]\n       lawspec lsp --stdio | lawspec mcp\n       lawspec prove [--solver <z3-executable>] [--proof-timeout <ms>] [--json]\n       lawspec check [--warn-matches] [--no-advice] | doctor | explain [<unit>::<law>] [--view eng|math|dev] | generate\n       lawspec evidence [<unit> | <unit>::<declaration>] [--attestation <file>]\n       lawspec test [--target <language>] [--fresh] [--seed <n>] [--attestation <file>] [--update-recorded] [--tag <t>] [--exclude-tag <t>] [--report junit=<path>] [--coverage] [--benchmarks]\n       lawspec mutate [paths...] [--target <language>] [--mutation-timeout <ms>] [--json]\n       lawspec describe --json\n       lawspec fetch | update [<package>]\n       lawspec package [--project <package directory>] [--output <archive.tgz>]\n       lawspec examples [--example payments] [--target <language>] [--output <directory>]\nOptions: --config <path>, --target <language>, --machine-bits <32|64>, --json, --no-cache, --timings, --locked, --offline\nGeneration: --dry-run, --check, --minify\nTargets: "
    ++ intercalate ", " targets

-- | main(): the exit code of a completed command.
cli :: (Monad m) => Invocation -> Arguments -> Command m Int
cli invocation arguments = do
  machineBits <- case option "machine-bits" arguments of
    Nothing -> pure Nothing
    Just bits -> case javascriptNumber bits of
      Just 32 -> pure (Just 32)
      Just 64 -> pure (Just 64)
      _ -> failWith "machineBits must be 32 or 64"
  let verb' = verb arguments
      name = fromMaybe "" verb'
      json = flag "json" arguments
      has key = present key arguments
      keys = given arguments ++ ["machineBits" | isJust machineBits]
      positionals = positional arguments
      cwd = invocationDirectory invocation
  case verb' of
    Nothing -> done (printLine usageText)
    Just v | v `elem` ["help", "--help", "-h"] -> done (printLine usageText)
    Just "--version" -> done (printLine (showVersion version))
    Just "prelude" -> do
      when (length positionals > 1 || any (/= "json") keys) (failWith "Usage: lawspec prelude [query] [--json]")
      result <- call "prelude" (JObject [("query", JString (case positionals of q : _ -> q; [] -> ""))]) >>= diagnostics json
      done . output json result $
        intercalate
          "\n"
          [ text "kind" entry ++ ": " ++ text "name" entry ++ maybe "" (\d -> if isTruthy d then " \x2014 " ++ jsString d else "") (member "definition" entry)
          | entry <- list "entries" result
          ]
    -- main() runs mutate after the checks of --strict and --no-advice and
    -- before every other check.
    Just "mutate" -> do
      when (has "strict") (failWith "--strict applies to advise")
      when (has "no-advice") (failWith "--no-advice applies to check and generate")
      mutateCommand (subcommand invocation) arguments cwd
    Just "reference" -> do
      when (not (null keys)) (failWith "Usage: lawspec reference [<name>]")
      referenceCommand (invocationResources invocation) positionals
    Just "learn" -> do
      when (has "strict") (failWith "--strict applies to advise")
      when (has "no-advice") (failWith "--no-advice applies to check and generate")
      when (not (null positionals) || any (/= "port") keys) (failWith "Usage: lawspec learn [--port <port>]")
      learnCommand (invocationResources invocation) (option "port" arguments)
    _ -> do
      when (has "strict" && name /= "advise") (failWith "--strict applies to advise")
      when (has "no-advice" && name `notElem` ["check", "generate"]) (failWith "--no-advice applies to check and generate")
      when (has "port") (failWith "--port applies to learn")
      if name == "project"
        then do
          when (length positionals /= 1 || any (`notElem` ["project", "config", "json", "languages"]) keys) $
            failWith "Usage: lawspec project init|adopt|status|validate [--project <directory>] [--json]; add targets with lawspec init --target"
          let action = concat (take 1 positionals)
          unless (action `elem` ["init", "adopt", "status", "validate"]) $
            failWith "Usage: lawspec project init|adopt|status|validate [--project <directory>]"
          when (has "config" && has "project") (failWith "Choose --config or --project")
          projectCommand (subcommand invocation) (invocationCanon invocation) arguments cwd
        else do
          when (has "languages") (failWith "--languages applies to project init/adopt")
          when (has "compile" && name /= "fmt") (failWith "--compile applies to fmt")
          when (name /= "fmt" && length positionals > (if name `elem` ["project", "explain", "evidence", "update"] then 1 else 0)) $
            failWith ("Unexpected argument: " ++ unwords positionals)
          if name == "examples"
            then do
              when (any has ["config", "project", "dry-run", "check"]) $
                failWith "examples supports --example, --target, --output, --machine-bits, --json and --minify only"
              let selected = maybe programTargets pure (option "target" arguments)
              when (any (`elem` artifactTargets) selected) $
                failWith "examples exports program targets; use init and generate for artifact targets"
              when (any (`notElem` programTargets) selected) $
                failWith ("Unknown target: " ++ fromMaybe "undefined" (option "target" arguments))
              forM_ (option "example" arguments) $ \example ->
                when (example /= "payments") (failWith ("Unknown example: " ++ example))
              examplesCommand arguments machineBits cwd selected
            else do
              when (any has ["solver", "proof-timeout", "proof-memory", "proof-rlimit", "proof-seed"] && name /= "prove") (failWith "Z3 options apply to prove")
              when (has "view" && name /= "explain") (failWith "--view applies to explain")
              when (has "output" && name /= "package") (failWith "--output is only supported by examples and package")
              when (has "example") (failWith "--example is only supported by examples")
              when (has "no-install" && name /= "init") (failWith "--no-install applies to init")
              when ((has "name" || has "group") && name /= "init") (failWith "--name and --group apply to init")
              when (any has ["release", "generated-source-dir", "generated-test-dir"] && (name /= "init" || option "target" arguments /= Just "java")) $
                failWith "--release, --generated-source-dir and --generated-test-dir apply to init --target java; other commands read them from the target in lawspec.edn"
              when (has "minify" && name `notElem` ["init", "generate", "examples", "test"]) (failWith "--minify applies to init, generate, test and examples")
              when (any testOption ["fresh", "seed", "tag", "exclude-tag", "report", "coverage", "update-recorded", "benchmarks"] && name /= "test") $
                failWith "--fresh, --seed, --update-recorded, --tag, --exclude-tag, --report, --coverage and --benchmarks apply to test"
              when (has "attestation" && name `notElem` ["evidence", "test"]) (failWith "--attestation applies to evidence and test")
              forM_ (option "seed" arguments) $ \seed ->
                unless (not (null seed) && all isDigit seed) (failWith "--seed must be a whole number")
              when (has "warn-matches" && name /= "check") (failWith "--warn-matches applies to check")
              when (has "stdio" && name /= "lsp") (failWith "--stdio applies to lsp")
              if name == "lsp"
                then do
                  unless (has "stdio") (failWith "lsp requires --stdio")
                  lspCommand cwd
                else do
                  configFile <-
                    if not (has "config") && name `notElem` ["init", "package", "mcp"] && not (name == "fmt" && not (null positionals))
                      then findManifest cwd
                      else pure (resolve cwd (fromMaybe "lawspec.edn" (option "config" arguments)))
                  let configRoot = takeDirectory configFile
                  grantRead [configRoot]
                  when (name == "mcp") $
                    when (any has ["target", "project", "output", "stdio"]) (failWith "mcp supports --config only")
                  case name of
                    "mcp" -> mcpCommand cwd (if has "config" then Just configFile else Nothing)
                    "describe" -> describeComponent invocation arguments configFile >>= done . printJson
                    _
                      | name `elem` ["fetch", "update"] -> fetchCommand invocation arguments name configFile
                      | name == "fmt" -> formatEntry arguments machineBits cwd configFile configRoot
                      | name == "init" -> initCommand invocation arguments machineBits configFile configRoot
                      | name == "package" -> packageCommand invocation arguments machineBits configFile configRoot
                      | name `notElem` ["check", "doctor", "evidence", "explain", "generate", "test", "prove", "inspect", "advise"] ->
                          failWith ("Unknown command: " ++ name)
                      | otherwise -> compileCommand invocation arguments machineBits name configFile configRoot
  where
    done action = 0 <$ action
    text key value = maybe "undefined" jsString (member key value)
    list key value = fromMaybe [] (member key value >>= arrayOf)
    testOption key = case key of
      "tag" -> isJust (M.lookup "tag" (lists arguments))
      "exclude-tag" -> isJust (M.lookup "exclude-tag" (lists arguments))
      _ -> present key arguments

-- | main().catch: the diagnostics as JSON on stdout under --json, otherwise
-- "lawspec: <message>" on stderr; exit code 1.
reportFailure :: (Monad m) => Arguments -> Failure -> Command m ()
reportFailure arguments (Failure message found) =
  if flag "json" arguments
    then
      printJson $
        JObject
          [ ( "diagnostics",
              maybe (JArray [JObject [("code", JString "cli"), ("message", JString message), ("at", JNull)]]) id found
            )
          ]
    else printError ("lawspec: " ++ message)

-- | Another invocation of the CLI, run within this one where the legacy CLI
-- spawned itself (process.execPath with lawspec.mjs) and read the child's
-- output: the arguments, in the working directory, as a child process
-- would run them. It starts from a closed policy and its own warnings and
-- created state, ends as main() and its catch would, and leaves this
-- invocation's session as it found it. What it prints is captured, not
-- shown; the deadline bounds every process it starts, and one it stops
-- leaves no exit code, as a killed child has none. Behaviour that is not
-- ported cannot be handed to the legacy CLI here, after this invocation's
-- own effects, so it stops this invocation too.
subcommand :: (Monad m) => Invocation -> Subcommand m
subcommand invocation argv cwd deadline = do
  saved <- getSession
  arguments <- either failWith pure (parseArguments argv)
  modifySession $ \s ->
    s
      { sessionPolicy = closed,
        sessionWarnings = S.empty,
        sessionCacheWarned = False,
        sessionCreatedState = Nothing,
        sessionCapture = Just [],
        sessionDeadline = deadline,
        sessionTimedOut = False
      }
  let restore = modifySession $ \s ->
        s
          { sessionPolicy = sessionPolicy saved,
            sessionWarnings = sessionWarnings saved,
            sessionCacheWarned = sessionCacheWarned saved,
            sessionCreatedState = sessionCreatedState saved,
            sessionCapture = sessionCapture saved,
            sessionDeadline = sessionDeadline saved,
            sessionTimedOut = sessionTimedOut saved
          }
      child = invocation {invocationArguments = argv, invocationDirectory = cwd}
  code <-
    (protectSession cwd >> cli child arguments) `catchE` \case
      Aborted failure -> 1 <$ (removeCreatedState >> reportFailure arguments failure)
      Unported reason -> restore >> throwE (Unported reason)
  after <- getSession
  restore
  let written = reverse (fromMaybe [] (sessionCapture after))
      stream which = B.concat [bytes | (kind, bytes) <- written, kind == which]
  pure
    Nested
      { nestedExit = if sessionTimedOut after then Nothing else Just code,
        nestedStdout = stream Stdout,
        nestedStderr = stream Stderr
      }

-- | output(value): a string as it is, anything else as indented JSON.
output :: (Monad m) => Bool -> Json -> String -> Command m ()
output json value plain = if json then printJson value else printLine plain

formatEntry :: (Monad m) => Arguments -> Maybe Integer -> FilePath -> FilePath -> FilePath -> Command m Int
formatEntry arguments machineBits cwd configFile configRoot = do
  let paths = positional arguments
      options' =
        FormatOptions
          { formatPaths = paths,
            formatCheck = flag "check" arguments,
            formatCompile = flag "compile" arguments,
            formatJson = flag "json" arguments,
            formatMachineBits = fromMaybe 64 machineBits
          }
  if not (null paths)
    then do
      -- The directories named, and the directories of the files named, are
      -- the project, so "fmt .." formats the parent of the working
      -- directory; the guard still refuses home and temp.
      let granted = cwd : map (resolve cwd) paths
      grantRead granted
      roots <- forM granted $ \path ->
        flip fmap (effectOr (Stat Follow path)) $ \case
          Right status | statusKind status == FileKind -> takeDirectory path
          _ -> path
      grantProject roots
      grantWrite granted
      formatCommand options' cwd paths []
    else do
      config <- readManifest configFile
      grantProject [configRoot]
      grantWrite [configRoot]
      packages <-
        recover
          (packageInput arguments "fmt" (not (formatCompile options')) cwd config configRoot)
          ( \failure ->
              if not (formatCompile options') && (take 7 (failureMessage failure) == "ENOENT:" || "Offline:" `elem` words (failureMessage failure))
                then pure []
                else abort failure
          )
      formatCommand options' configRoot (strings "sources" config) packages
  where
    strings key value = [entry | Just items <- [member key value >>= arrayOf], JString entry <- items]

-- | packageInput(owner, root): the resolved packages and the dependency
-- ranges, with the package identity of a package's own manifest.
packageInput :: (Monad m) => Arguments -> String -> Bool -> FilePath -> Json -> FilePath -> Command m [(String, Json)]
packageInput arguments name optional cwd owner root = do
  let readOnly = name `elem` ["inspect", "advise"]
  resolved <-
    resolveDependencies
      (join root "lawspec.edn")
      owner
      (resolveOptions cwd)
        { resolveLocked = flag "locked" arguments,
          resolveReadOnly = readOnly,
          resolveWriteLock = not readOnly,
          resolveOffline = optional || readOnly || flag "offline" arguments
        }
  pure
    ( [ ("packages", JArray (resolvedPackages resolved)),
        ("dependencies", dependencyRanges owner)
      ]
        ++ maybe [] (\identity -> [("package", identity)]) (member "package" owner)
    )

-- | The fields of a target that the compiler's target requests take.
targetFields :: Json -> [(String, Json)]
targetFields target =
  ("target", fromMaybe JNull (member "language" target))
    : [(key, value) | key <- ["sourceDir", "testDir", "generatedSourceDir", "generatedTestDir", "release", "nativeBindings", "actors"], Just value <- [member key target]]

language :: Json -> String
language target = maybe "" jsString (member "language" target)

compileCommand :: (Monad m) => Invocation -> Arguments -> Maybe Integer -> String -> FilePath -> FilePath -> Command m Int
compileCommand invocation arguments machineBits name configFile configRoot = do
  config <- readManifest configFile
  let json = flag "json" arguments
      has key = present key arguments
      targetOption = option "target" arguments
      configured = fromMaybe [] (member "targets" config >>= arrayOf)
      layers = fromMaybe [] (member "verification" config >>= member "layers" >>= arrayOf)
      noNativeLayers =
        name == "test"
          && not (has "benchmarks")
          && member "manifestVersion" config == Just (integer 1)
          && not (any (`elem` map JString ["exhaustive", "property", "examples", "model"]) layers)
  when (name == "inspect" && isNothing targetOption) (failWith "inspect requires --target <target>")
  forM_ targetOption $ \wanted ->
    unless (any ((== wanted) . language) configured) (failWith "No matching configured target")
  when (name == "test" && maybe False (`elem` artifactTargets) targetOption) $
    failWith (fromMaybe "" targetOption ++ " is an artifact target and cannot execute application laws")
  let selected =
        [ target
        | target <- configured,
          maybe True (== language target) targetOption,
          name /= "test" || language target `notElem` artifactTargets
        ]
  when (name `elem` ["doctor", "generate", "test", "inspect"] && null selected && not noNativeLayers) $
    failWith "No matching configured target"
  let roots = [resolve configRoot (maybe "" jsString (member "root" target)) | target <- selected]
  -- A Gradle project's wrapper runs its tests: prepare.mjs gradleFor.
  selected' <- forM (zip selected roots) $ \(target, root) ->
    if language target `elem` ["kotlin", "groovy"] && not (maybe False isTruthy (member "gradle" target))
      then do
        let wrapper = join root "gradlew"
        grantRead [wrapper]
        exists <- either (const False) (const True) <$> effectOr (Stat Follow wrapper)
        pure (setMember "gradle" (JString (if exists then wrapper else "gradle")) target)
      else pure target
  when (length (nub roots) /= length roots) (failWith "Each configured target needs its own project root")
  grantProject (configRoot : roots)
  if name == "doctor"
    then do
      location <- cacheLocation (has "no-cache") config configRoot (invocationDirectory invocation)
      doctorCommand json (zip selected' roots) location (buildDigest invocation)
    else do
      forM_ (member "machineBits" config) $ \bits ->
        unless (bits `elem` [integer 32, integer 64]) (failWith "machineBits must be 32 or 64")
      forM_ (member "cache" config) $ \value -> case value of
        JBool _ -> pure ()
        _ -> failWith "cache must be true or false"
      forM_ (member "cacheDirectory" config) $ \value -> case value of
        JString (_ : _) -> pure ()
        _ -> failWith "cacheDirectory must be the path of a directory"
      forM_ (member "attestation" config) $ \value -> case value of
        JString _ -> pure ()
        _ -> failWith "attestation must be the path of an environment attestation"
      grantWrite (configRoot : roots)
      noCacheDirectory <- pure (has "no-cache")
      location <- cacheLocation noCacheDirectory config configRoot (invocationDirectory invocation)
      cache <-
        if name `elem` ["inspect", "advise"]
          then pure Nothing
          else cacheDirectory invocation configRoot location
      clock <- effect (\problem -> Failure (errorMessage problem) Nothing) GetClock
      sources <- collectSources configRoot [entry | Just items <- [member "sources" config >>= arrayOf], JString entry <- items] configRoot
      packages <- packageInput arguments name False (invocationDirectory invocation) config configRoot
      let version' = case member "component" config >>= member "version" of
            Just value | isTruthy value -> Just value
            _ -> case member "package" config >>= member "version" of
              Just value | isTruthy value -> Just value
              _ -> Nothing
          input =
            jsObject
              ( maybe [] (\directory -> [("cacheDirectory", JString directory)]) cache
                  ++ [("progress", JArray [JString "timings"]) | has "timings"]
                  ++ [ ("advice", JBool (not (has "no-advice"))),
                       ( "sources",
                         JArray [JObject [("path", JString path'), ("content", JString content)] | (path', content) <- sources]
                       ),
                       ("languageProfile", fromMaybe JNull (member "languageProfile" config)),
                       ("verification", fromMaybe (JObject [("layers", JArray [])]) (member "verification" config))
                     ]
                  ++ packages
                  ++ [("generation", value) | Just value <- [member "generation" config]]
                  ++ [("machineBits", maybe (fromMaybe (integer 64) (member "machineBits" config)) integer machineBits)]
                  ++ [("projectVersion", value) | Just value <- [version']]
                  ++ [("now", JString (isoTime (wallMilliseconds clock)))]
              )
          advised = [(language target, root, targetFields target) | (target, root) <- zip selected' roots]
          observing input' =
            Observing
              { observingInput = input',
                observingTargets = zip selected' roots,
                observingConfigRoot = configRoot,
                observingConfig = config,
                observingBuild = buildDigest invocation,
                observingHost = hostIdentity (invocationHost invocation) (buildDigest invocation)
              }
      case name of
        "inspect" -> do
          result <- call "inspect" (jsObject (members input ++ concatMap targetFields (take 1 selected'))) >>= diagnostics json
          0 <$ if json then printJson result else outputValue (member "interface" result)
        "check" -> do
          checked <- call "check" (jsObject (members input ++ [("warnMatches", JBool True) | has "warn-matches"])) >>= diagnostics json
          result <-
            if has "no-advice"
              then pure checked
              else do
                advice <- authoringReport json config input advised
                unless json (printAdvice advice)
                pure (setMember "advice" advice checked)
          forM_ selected' $ \target ->
            forM_ (member "nativeBindings" target) $ \bindings ->
              call "check" (jsObject (members input ++ [("nativeBindings", bindings)] ++ [("actors", value) | Just value <- [member "actors" target]])) >>= diagnostics json
          let laws = fromMaybe [] (member "laws" result >>= arrayOf)
              selection = member "verification" result >>= member "selection"
          0
            <$ output
              json
              result
              ( "Compiled "
                  ++ show (length laws)
                  ++ " law(s). Intrinsic definition checks passed."
                  ++ if selection == Just (JString "no-selected-checks")
                    then " No law checks selected."
                    else evidenceSummary (fromMaybe [] (member "evidence" result >>= arrayOf))
              )
        "advise" -> do
          _ <- call "check" (jsObject (members input ++ [("advice", JBool False)])) >>= diagnostics json
          report <- authoringReport json config input advised
          let ok = member "ok" report == Just (JBool True)
          if json
            then printJson report
            else do
              printAdvice report
              printLine
                ( if ok
                    then "Selected authoring checks complete; no unresolved findings."
                    else "Authoring review required; see findings and analysis limits."
                )
          pure (if has "strict" && not ok then 1 else 0)
        "prove" -> proveCommand invocation arguments input
        "explain" -> do
          let request = jsObject (members input ++ [("view", JString (fromMaybe "eng" (option "view" arguments)))] ++ [("law", JString law) | law : _ <- [positional arguments], not (null law)])
          explained <- call "explain" request >>= diagnostics json
          expanded <- call "expand" input >>= diagnostics json
          -- The compiler words the law; the CLI only reads the recorded
          -- native observations and passes their evidence rows in.
          let evidence = fromMaybe [] (member "evidence" expanded >>= arrayOf)
          attestation <- readAttestation arguments config configRoot (invocationDirectory invocation)
          observations <- readNativeObservations (observing input) evidence attestation
          explained' <-
            if null observations
              then pure explained
              else call "explain" (jsObject (members request ++ [("evidence", JArray (attachNativeEvidence evidence observations))])) >>= diagnostics json
          0 <$ outputValue (member (if json then "explanations" else "text") explained')
        "evidence" -> evidenceCommand invocation arguments config (observing input)
        "test"
          | not noNativeLayers -> runTests invocation arguments config input (zip selected' roots) configRoot
          | otherwise -> do
              checked <- call "check" input >>= diagnostics json
              0
                <$ output
                  json
                  ( JObject
                      [ ("verification", fromMaybe JNull (member "verification" checked)),
                        ("evidence", fromMaybe JNull (member "evidence" checked)),
                        ("testsExecuted", integer 0)
                      ]
                  )
                  ( if null layers
                      then "No law verification layers selected. Intrinsic definition checks passed; no law checks ran."
                      else "No native law checks selected. See lawspec evidence for the selected static analyses."
                  )
        _ -> generate arguments config input selected' roots advised
  where
    -- output(value) for a value the compiler gave: a string prints as
    -- itself, and a missing one as console.log(undefined) does.
    outputValue = \case
      Just (JString plain) -> printLine plain
      Just value -> printJson value
      Nothing -> printLine "undefined"

generate :: (Monad m) => Arguments -> Json -> Json -> [Json] -> [FilePath] -> [(String, FilePath, [(String, Json)])] -> Command m Int
generate arguments config input selected roots advised = do
  let json = flag "json" arguments
      has key = present key arguments
      dryRun = has "dry-run"
      checkOnly = has "check"
      minify = flag "minify" arguments
  when (dryRun && checkOnly) (failWith "--dry-run and --check are mutually exclusive")
  advisory <-
    if has "no-advice"
      then pure Nothing
      else Just <$> authoringReport json config input advised
  unless json (forM_ advisory printAdvice)
  planned <- forM selected $ \target -> do
    plannedFiles <- call "planGeneration" (jsObject (members input ++ targetFields target ++ [("minify", JBool minify)])) >>= diagnostics json
    pure (fromMaybe (JArray []) (member "files" plannedFiles))
  let artifacts = map artifactsFrom planned
  -- Every program target's toolchain must be ready before anything is written.
  reports <- forM (zip3 selected roots planned) $ \(target, root, files) -> doctor target root (fromMaybe [] (arrayOf files))
  let failed = [report | report <- reports, member "ok" report /= Just (JBool True)]
  unless (null failed) . failWith $
    intercalate "\n" [maybe "undefined" jsString (member "target" r) ++ ": " ++ maybe "undefined" jsString (member "message" r) ++ "\n" ++ maybe "undefined" jsString (member "instructions" r) | r <- failed]
  plans <- forM (zip roots artifacts) $ \(root, files) -> planWrites root files ".lawspec/generated.json" (const False)
  unless (dryRun || checkOnly) (applyWrites plans)
  let summaries =
        [ ( language target,
            jsObject
              ( [("target", JString (language target))]
                  ++ maybe [] (\advice -> [("advice", advice)]) advisory
                  ++ [ ("changes", JArray [JObject [("action", JString (actionName (changeAction c))), ("path", JString (changeRelative c))] | c <- planChanges plan]),
                       ("preservedAdapters", JArray (map JString (planPreserved plan))),
                       ("adapterUpdates", JArray [JObject [("path", JString (adapterPath a)), ("requiredAdapter", JString (requiredAdapter a))] | a <- planAdapterUpdates plan]),
                       ("test", maybe JNull JString (testLine target root))
                     ]
              ),
            plan
          )
        | (target, root, plan) <- zip3 selected roots plans
        ]
  if json
    then printJson (JArray [summary | (_, summary, _) <- summaries])
    else
      printLine . intercalate "\n" $
        [ target
            ++ ": "
            ++ show (length (planChanges plan))
            ++ " "
            ++ (if dryRun || checkOnly then "planned" else "applied")
            ++ " change(s), "
            ++ show (length (planPreserved plan))
            ++ " user adapter(s) preserved."
            ++ ( if null (planAdapterUpdates plan)
                   then ""
                   else "\nReview required adapter signatures:\n" ++ intercalate "\n" [adapterPath a ++ "\n" ++ requiredAdapter a | a <- planAdapterUpdates plan]
               )
            ++ "\n"
            ++ maybe "Artifact generation complete." ("Test: " ++) (stringOf =<< member "test" summary)
        | (target, summary, plan) <- summaries
        ]
  pure (if checkOnly && any (not . null . planChanges) plans then 1 else 0)
  where
    -- testCommand(target, root): an artifact target has no test command.
    testLine target root
      | language target `elem` artifactTargets = Nothing
      | otherwise = (\command -> "(cd " ++ quote root ++ " && " ++ command ++ ")") <$> testCommand (language target)
    quote value = "'" ++ concatMap (\c -> if c == '\'' then "'\\''" else [c]) value ++ "'"

-- | The evidence summary check prints: each obligation status, strongest
-- first; exempted, refuted and the harness statuses only when present.
evidenceSummary :: [Json] -> String
evidenceSummary [] = ""
evidenceSummary evidence =
  " Evidence: " ++ intercalate ", " [show (count status) ++ " " ++ label | (index, (status, label)) <- zip [0 :: Int ..] statuses, index < harnessFrom || count status > 0] ++ "."
  where
    count status = length [() | item <- evidence, member "status" item == Just (JString status)]
    harnessFrom = length (takeWhile ((/= "exempted") . fst) statuses)
    statuses = evidenceStatuses
