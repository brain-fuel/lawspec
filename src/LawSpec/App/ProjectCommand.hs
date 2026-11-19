-- | @lawspec project@, ported from project.mjs and its wiring in
-- lawspec.mjs: @init@ and @adopt@ write lawspec.edn (and a starter unit)
-- beside a Canon configuration, and @status@ and @validate@ report Canon,
-- the mandatory definition checks and the selected law verification, each
-- with its own status, and exit 0, 1 or 2 on them.
--
-- Canon itself stays outside the core: the canon library (grammatical-
-- parsers, yaml, typed-process and async) is not part of this build and does
-- not build for wasm32-wasi. Every host ships a native Canon instead
-- ('CanonTool': tools/build-canon.sh builds the executable and gathers
-- Rice's Tax's presets). Setting Canon up is ricestax@0.4.3's setup.mjs
-- initialize(), done here over the host's files with the presets the host
-- ships; the checks run the canon executable the CANON variable names or,
-- without one, the Canon the host ships, where the legacy CLI ran the
-- ricestax npm package through Node. The proof and native rows of
-- validate, which the legacy CLI produced by running lawspec prove and
-- lawspec test as child processes, run those commands in this process
-- ('Subcommand') and read their output as it read the children's.
-- ref:DEC-haskell-application-port ref:DEC-native-canon
module LawSpec.App.ProjectCommand
  ( projectCommand,
    projectExitCode,
    canonSetupVersion,
    canonExpectedVersion,
    canonReportedVersion,
  )
where

import Control.Monad (forM_, unless, when)
import Data.Char (isAscii, isAlphaNum, isDigit, ord)
import Data.List (intercalate, isPrefixOf, nub)
import Data.Maybe (fromMaybe, isJust)
import LawSpec.App.Arguments
import LawSpec.App.CanonDownload (resolveCanon)
import LawSpec.App.Command
import LawSpec.App.Compiler (call)
import LawSpec.App.Files (atomicWrite, collectSources, safePath)
import LawSpec.App.Json
import LawSpec.App.Packages (ResolveOptions (..), Resolved (..), resolveDependencies, resolveOptions, toManifest)
import LawSpec.App.Process (Run (..), launch, runProcess)
import LawSpec.App.Project (dependencyRanges, environment, isoTime, readManifest)
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, resolve, takeDirectory)
import LawSpec.Manifest.EDN (writeManifest)

-- | The ricestax release whose Canon setup project.mjs pins.
canonSetupVersion :: String
canonSetupVersion = "0.4.3"

-- | The layers whose checks run in a native test suite.
executionLayers :: [String]
executionLayers = ["property", "examples", "exhaustive", "model"]

-- | lawspec project init|adopt|status|validate, after main()'s usage checks,
-- with the Canon the host ships, if any.
projectCommand :: (Monad m) => Subcommand m -> Maybe CanonSource -> Arguments -> FilePath -> Command m Int
projectCommand subcommand canonTool arguments cwd = do
  let action = concat (take 1 (positional arguments))
      config = truthy "config"
      configFile = resolve cwd (fromMaybe "lawspec.edn" config)
      root = if isJust config then takeDirectory configFile else resolve cwd (fromMaybe "." (truthy "project"))
      json = flag "json" arguments
  if action `elem` ["init", "adopt"]
    then do
      -- lawspec.mjs: {languages: options.languages.split(',')} when given,
      -- otherwise setupProject's ['folio'].
      let languages = maybe ["folio"] (splitOn ',') (truthy "languages")
      result <- setupProject canonTool root (action == "adopt") languages
      if json
        then printJson result
        else
          printLine
            ( "LawSpec "
                ++ text "manifest" result
                ++ "; Canon "
                ++ text "canon" result
                ++ " in "
                ++ root
                ++ ". Add an application with lawspec init --target <language>."
            )
      pure 0
    else do
      when (isJust (truthy "languages")) (failWith "--languages applies to project init/adopt")
      report <- inspectProject subcommand canonTool cwd root (action == "validate") (if isJust config then configFile else join root "lawspec.edn")
      if json
        then printJson report
        else printLine (intercalate "\n" [key ++ ": " ++ compact value | (key, value) <- members report, key /= "root"])
      pure (projectExitCode report)
  where
    truthy name = case option name arguments of
      Just value | not (null value) -> Just value
      _ -> Nothing
    text key value = maybe "undefined" jsString (member key value)
    splitOn separator value = case break (== separator) value of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitOn separator rest

-- | project.mjs exists(): lstat, with only a missing path as false.
exists :: (Monad m) => FilePath -> Command m Bool
exists path' =
  effectOr (Stat NoFollow path') >>= \case
    Right _ -> pure True
    Left (HostError NotFound _) -> pure False
    Left problem -> abort (nodeFailure "lstat" path' problem)

-- | project.mjs setupProject: every check before anything is written; then
-- Canon's setup with the presets the host ships, when the project has no
-- canon.yaml, the manifest and, in a project without laws, a starter unit.
setupProject :: (Monad m) => Maybe CanonSource -> FilePath -> Bool -> [String] -> Command m Json
setupProject canonTool root adopt languages = do
  grantRead [root]
  forM_ ["lawspec.json", "lawspec-package.json"] $ \old -> do
    found <- exists (join root old)
    when found (failWith (old ++ " is no longer supported; use lawspec.edn"))
  let manifestFile = join root "lawspec.edn"
  hasManifest <- exists manifestFile
  hasCanon <- exists (join root "canon.yaml")
  when (not adopt && (hasManifest || hasCanon)) (failWith "Project metadata already exists; use lawspec project adopt")
  when hasManifest (() <$ readManifest manifestFile)
  unless hasCanon $ do
    halfSetUp <- exists (join root ".ricestax")
    when halfSetUp (failWith ".ricestax exists without canon.yaml; review the incomplete Canon setup")
  -- Decided during preflight, as project.mjs resolved the ricestax package
  -- then, so that a missing Canon writes nothing.
  presets <-
    if hasCanon
      then pure Nothing
      else maybe (failWith (missingCanon "Setting Canon up")) (fmap (Just . canonPresets) . resolveCanon) canonTool
  -- A tiny empty unit makes mandatory validation available before choosing a target.
  starter <- if hasManifest then pure False else not <$> exists (join root "laws")
  -- The root is a project root once it exists; one this is about to create
  -- is only a write root, which the guard lets it make (mkdir(root,
  -- {recursive: true})).
  rootExists <- exists root
  when rootExists (grantProject [root])
  grantWrite [root]
  unless rootExists $ do
    effect (nodeFailure "mkdir" root) (MakeDirectories Nothing root)
    grantProject [root]
  forM_ presets $ \directory -> do
    initializeCanon directory root languages
    -- Upstream setup does not create a decision ledger. Never replace an existing one.
    forM_ ["canonical_decisions.yaml", "canonical_refs.yaml", "canonical_exemptions.yaml"] $ \name -> do
      found <- exists (join root name)
      unless found $ do
        file <- safePath root name
        atomicWrite file "{}\n" True
  unless hasManifest $ do
    when starter $ do
      file <- safePath root "laws/project.lawspec"
      atomicWrite file "unit project\nend unit\n" True
    file <- safePath root "lawspec.edn"
    atomicWrite file (writeManifest False (toManifest (newManifest root))) True
  pure
    ( JObject
        [ ("root", JString root),
          ("manifest", JString (if hasManifest then "preserved" else "created")),
          ("canon", JString (if hasCanon then "preserved" else "created")),
          ("canonSetup", JString ("ricestax@" ++ canonSetupVersion)),
          ("applicationFilesChanged", JBool False)
        ]
    )

-- | What a command that needs Canon says when the host ships none, where
-- project.mjs said the optional ricestax package was not installed.
missingCanon :: String -> String
missingCanon purpose =
  purpose
    ++ " needs the Canon LawSpec ships (canon "
    ++ canonVersion
    ++ " with the ricestax@"
    ++ canonSetupVersion
    ++ " presets), which this installation lacks. Install LawSpec with its Canon for this platform"
    ++ (if purpose == "Checking Canon" then ", or set CANON to a matching canon executable." else ".")

-- | The canon release the shipped executable is (tools/build-canon.sh).
canonVersion :: String
canonVersion = "0.2.3"

-- | ricestax@0.4.3 setup.mjs initialize(root, names): the selected
-- languages' profiles from the presets' languages.json, the grammars,
-- provenance.json and CANON-LICENSE copied into a staging folder that is
-- renamed to .ricestax, and canon.yaml written beside it, exclusively. The
-- staging folder is removed if anything fails. The folder setup.mjs named
-- by its process id is named here by the clock.
initializeCanon :: (Monad m) => FilePath -> FilePath -> [String] -> Command m ()
initializeCanon presets root names = do
  grantRead [presets]
  let catalogFile = join presets "languages.json"
  catalog <- effect (nodeFailure "open" catalogFile) (ReadFile catalogFile) >>= either failWith pure . parseJson . fromUtf8
  let selected = nub names
      profiles = members catalog
  when (null selected) (failWith "Choose languages: ricestax init --languages java,calm")
  forM_ selected $ \name -> unless (any ((== name) . fst) profiles) (failWith ("Unknown language: " ++ name))
  -- Validate all destinations before touching an existing project. No merge or overwrite.
  forM_ ["canon.yaml", ".ricestax"] $ \name -> do
    found <- exists (join root name)
    when found (failWith (name ++ " already exists. Initialize a separate directory and merge its configuration deliberately."))
  clock <- effect (\problem -> Failure (errorMessage problem) Nothing) GetClock
  let staging = join root (".ricestax-init-" ++ show (wallMilliseconds clock))
  staged <- exists staging
  when staged (failWith ("EEXIST: file already exists, mkdir '" ++ staging ++ "'"))
  effect (nodeFailure "mkdir" staging) (MakeDirectories Nothing staging)
  let languages = jsObject [(name, embedsFor name (lookupProfile name)) | name <- selected]
      lookupProfile name = maybe JNull id (lookup name profiles)
      -- Folio's embedded languages are only the selected ones.
      embedsFor name profile
        | name == "folio",
          Just embeds <- member "embeds" profile =
            setMember "embeds" (jsObject [(embedded, value) | (embedded, value) <- members embeds, embedded `elem` selected]) profile
        | otherwise = profile
      config =
        JObject
          [ ("version", JString "0.1.0"),
            ("ignore", JArray (map JString [".ricestax", "node_modules", "target", "build", "dist", ".venv", "__pycache__"])),
            ("languages", languages)
          ]
      record = JObject [("package", JString "ricestax"), ("profiles", JArray (map JString selected))]
      ricestax = join root ".ricestax"
  recover
    ( do
        copyTree (join presets "grammars") (join staging "grammars")
        forM_ ["provenance.json", "CANON-LICENSE"] $ \name -> copyFile (join presets name) (join staging name)
        writeNew (join staging "languages.json") (stringify record ++ "\n")
        effect (nodeFailure "rename" staging) (Rename staging ricestax)
        -- JSON is a YAML subset, so no extra runtime YAML library is required.
        writeNew (join root "canon.yaml") (stringify config ++ "\n")
    )
    ( \failure -> do
        _ <- effectOr (Remove Recursive staging)
        abort failure
    )
  where
    writeNew file content = effect (nodeFailure "open" file) (WriteFile Create Nothing file (utf8 content))
    -- fs.cp: a file keeps its bytes and permission bits; a folder its bits.
    copyFile from to = do
      status <- effect (nodeFailure "stat" from) (Stat Follow from)
      bytes <- effect (nodeFailure "open" from) (ReadFile from)
      effect (nodeFailure "copyfile" to) (WriteFile Create (statusPermissions status) to bytes)
    copyTree from to = do
      status <- effect (nodeFailure "stat" from) (Stat Follow from)
      effect (nodeFailure "mkdir" to) (MakeDirectories (statusPermissions status) to)
      entries <- effect (nodeFailure "scandir" from) (ListDirectory from)
      forM_ entries $ \entry -> case entryKind entry of
        DirectoryKind -> copyTree (join from (entryName entry)) (join to (entryName entry))
        _ -> copyFile (join from (entryName entry)) (join to (entryName entry))

-- | The manifest setupProject writes, named after the root's base name with
-- every UTF-16 unit outside [A-Za-z0-9_.-] replaced by a hyphen.
newManifest :: FilePath -> Json
newManifest root =
  JObject
    [ ("manifestVersion", integer 1),
      ("component", JObject [("name", JString (concatMap safe (baseName root))), ("version", JString "0.1.0")]),
      ("languageProfile", JString "1.0-rc.2"),
      ("verification", JObject [("layers", JArray [])]),
      ("sources", JArray [JString "laws"]),
      ("targets", JArray [])
    ]
  where
    safe c
      | isAscii c && (isAlphaNum c || c `elem` ("_.-" :: String)) = [c]
      | ord c >= 0x10000 = "--"
      | otherwise = "-"
    baseName = reverse . takeWhile (/= '/') . reverse

-- | What inspectCanon will do, decided before anything runs.
data CanonStep
  = CanonRow Json
  | RunCanon [String] (Maybe String)

-- | project.mjs inspectProject.
inspectProject :: (Monad m) => Subcommand m -> Maybe CanonSource -> FilePath -> FilePath -> Bool -> FilePath -> Command m Json
inspectProject subcommand canonTool cwd root validate configFile = do
  grantRead [root, configFile]
  canonStep <- recover (planCanon canonTool root) (\failure -> pure (CanonRow (incomplete (failureMessage failure))))
  manifest <- recover (Right <$> readManifest configFile) (pure . Left)
  canon <- case canonStep of
    CanonRow row -> pure row
    RunCanon command expected -> inspectCanon root command expected validate
  rows <- case manifest of
    Left failure -> pure [("definitions", failed failure)]
    Right config -> definitionRows subcommand cwd root validate configFile config
  pure (JObject ([("root", JString root), ("canon", canon)] ++ rows))
  where
    failed failure =
      JObject
        [ ("status", JString "incomplete"),
          ("detail", JString (failureMessage failure)),
          ("diagnostics", fromMaybe (JArray []) (failureDiagnostics failure))
        ]

incomplete :: String -> Json
incomplete detail = JObject [("status", JString "incomplete"), ("detail", JString detail)]

layersOf :: Json -> [String]
layersOf config = [layer | Just items <- [member "verification" config >>= member "layers" >>= arrayOf], JString layer <- items]

targetsOf :: Json -> [Json]
targetsOf config = fromMaybe [] (member "targets" config >>= arrayOf)

-- | inspectCanon up to running Canon: canon.yaml, the version it expects,
-- and the command: the executable CANON names or, without one, the Canon
-- the host ships, where the legacy CLI ran the ricestax npm package's CLI
-- through Node.
planCanon :: (Monad m) => Maybe CanonSource -> FilePath -> Command m CanonStep
planCanon canonTool root = do
  let file = join root "canon.yaml"
  found <- exists file
  if not found
    then pure (CanonRow (incomplete "No canon.yaml; run lawspec project adopt"))
    else do
      bytes <- effect (nodeFailure "open" file) (ReadFile file)
      binary <- environment "CANON"
      let expected = canonExpectedVersion (fromUtf8 bytes)
      case (binary, canonTool) of
        (Just program, _) | not (null program) -> pure (RunCanon [program] expected)
        (_, Just source) -> (\tool -> RunCanon (canonCommand tool) expected) <$> resolveCanon source
        _ -> pure (CanonRow (incomplete (missingCanon "Checking Canon")))

-- | Run Canon: its version, compared with the one canon.yaml expects by
-- major and minor, then check (validate) or decisions (status).
inspectCanon :: (Monad m) => FilePath -> [String] -> Maybe String -> Bool -> Command m Json
inspectCanon root command expected validate = do
  version <- runTool root command ["version"]
  let actual = case member "output" version of
        Just (JString output) -> canonReportedVersion output
        _ -> Nothing
      minor = intercalate "." . take 2 . splitDots
      compatible = case (actual, expected) of
        (Just reported, Just wanted) -> minor wanted == minor reported
        (Just _, Nothing) -> True
        _ -> False
  if member "status" version /= Just (JString "passed") || not compatible
    then
      pure
        ( JObject
            ( [("status", JString "incomplete")]
                ++ [("expectedVersion", JString v) | Just v <- [expected]]
                ++ [("actualVersion", JString v) | Just v <- [actual]]
                ++ [("detail", JString "Canon version unavailable or incompatible. Set CANON to the matching native executable; existing metadata is preserved.")]
            )
        )
    else do
      result <- runTool root command [if validate then "check" else "decisions"]
      pure (setMember "version" (maybe JNull JString actual) result)
  where
    splitDots text = case break (== '.') text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitDots rest

-- | project.mjs run(): the status a command's exit code gives, its standard
-- output as JSON when it parses (or as text), and its standard error or
-- start failure. The command is a program and the arguments before these.
runTool :: (Monad m) => FilePath -> [String] -> [String] -> Command m Json
runTool root command arguments = do
  run <- runProcess (launch program (leading ++ arguments) root)
  let status = case (runError run, runExit run) of
        (Nothing, Just (ExitCode 0)) -> "passed"
        (Nothing, Just (ExitCode 2)) -> "incomplete"
        (Nothing, Just (ExitCode _)) -> "failed"
        _ -> "incomplete"
      exitCode = case runExit run of
        Just (ExitCode code) | runError run == Nothing -> integer (toInteger code)
        _ -> JNull
      stdout = fromUtf8 (runStdout run)
      stderr = fromUtf8 (runStderr run)
      output = case runError run of
        Just _ -> ("output", JString "")
        Nothing -> either (const ("output", JString stdout)) (\value -> ("result", value)) (parseJson stdout)
      detail = case runError run of
        Just message -> [("detail", JString (syncMessage message))]
        Nothing -> [("detail", JString stderr) | not (null stderr)]
  pure (JObject ([("status", JString status), ("exitCode", exitCode), output] ++ detail))
  where
    (program, leading) = case command of
      first : rest -> (first, rest)
      [] -> ("", [])
    -- spawnSync names itself in a start failure, where spawn names itself.
    syncMessage message
      | "spawn " `isPrefixOf` message = "spawnSync " ++ program ++ " " ++ last (words message)
      | otherwise = message

-- | The definition and verification rows: mandatory validation with no law
-- checks selected, then, for validate when it passed, the manifest's
-- selection.
definitionRows :: (Monad m) => Subcommand m -> FilePath -> FilePath -> Bool -> FilePath -> Json -> Command m [(String, Json)]
definitionRows subcommand cwd root validate configFile config = do
  stage <-
    recover
      ( Right <$> do
          resolved <- resolveDependencies configFile config (resolveOptions cwd) {resolveWriteLock = False}
          sources <- collectSources root [entry | Just items <- [member "sources" config >>= arrayOf], JString entry <- items] root
          clock <- effect (\problem -> Failure (errorMessage problem) Nothing) GetClock
          let version' = case member "component" config >>= member "version" of
                Just value -> Just value
                Nothing -> member "package" config >>= member "version"
              input =
                [ ("sources", JArray [JObject [("path", JString path'), ("content", JString content)] | (path', content) <- sources]),
                  ("languageProfile", fromMaybe JNull (member "languageProfile" config)),
                  ("machineBits", fromMaybe (integer 64) (member "machineBits" config)),
                  ("packages", JArray (resolvedPackages resolved)),
                  ("dependencies", dependencyRanges config)
                ]
                  ++ [("package", value) | Just value <- [member "package" config]]
                  ++ [("projectVersion", value) | Just value <- [version']]
                  ++ [("now", JString (isoTime (wallMilliseconds clock)))]
          checked <- call "check" (jsObject (input ++ [("verification", JObject [("layers", JArray [])])]))
          pure (input, checked)
      )
      (pure . Left)
  case stage of
    Left failure ->
      pure
        [ ( "definitions",
            JObject
              [ ("status", JString "incomplete"),
                ("detail", JString (failureMessage failure)),
                ("diagnostics", fromMaybe (JArray []) (failureDiagnostics failure))
              ]
          )
        ]
    Right (input, checked) -> do
      let found = diagnosticsOf checked
          passed = null found
          definitions = JObject [("status", JString (if passed then "passed" else "failed")), ("diagnostics", JArray found)]
          verification =
            JObject
              ( [("layers", layers), ("status", JString "not-verified")]
                  ++ [("evidence", value) | Just value <- [member "evidence" checked]]
              )
      if not (validate && passed)
        then pure [("definitions", definitions), ("verification", verification)]
        else do
          selected <-
            recover
              (Right <$> call "check" (jsObject (input ++ [("verification", fromMaybe (JObject [("layers", JArray [])]) (member "verification" config))])))
              (pure . Left)
          case selected of
            Left failure ->
              pure
                [ ("definitions", definitions),
                  ("verification", setMember "detail" (JString (failureMessage failure)) (setMember "status" (JString "incomplete") verification))
                ]
            Right result -> do
              let selectedFound = diagnosticsOf result
                  status
                    | not (null selectedFound) = "failed"
                    | maybe False (not . null) (arrayOf layers) = "completed"
                    | otherwise = "not-verified"
                  verification' =
                    JObject
                      ( [("layers", layers), ("status", JString status)]
                          ++ [("selection", value) | Just value <- [member "verification" result]]
                          ++ [("diagnostics", JArray selectedFound)]
                          ++ [("evidence", value) | Just value <- [member "evidence" result]]
                      )
              -- Solver discharge settles the obligations the check left;
              -- its own rows replace the check's.
              proof <-
                if "proof" `elem` layersOf config
                  then Just <$> childRow ["prove", "--config", configFile, "--json"]
                  else pure Nothing
              let verification'' = case proof >>= member "result" >>= member "evidence" of
                    Just evidence@(JArray _) -> setMember "evidence" evidence verification'
                    _ -> verification'
              native <-
                if any (`elem` executionLayers) (layersOf config)
                  then
                    if null (targetsOf config)
                      then pure [("native", incomplete "Selected execution layers have no application target")]
                      else (\row -> [("native", row)]) <$> childRow ["test", "--config", configFile, "--json"]
                  else pure []
              pure ([("definitions", definitions), ("verification", verification'')] ++ [("proof", row) | Just row <- [proof]] ++ native)
  where
    layers = fromMaybe (JArray []) (member "verification" config >>= member "layers")
    diagnosticsOf result = fromMaybe [] (member "diagnostics" result >>= arrayOf)
    -- project.mjs run() for the CLI itself, in the project root: the status
    -- its exit code gives, its standard output as JSON when it parses (or
    -- as text), and its standard error when it printed any.
    childRow argv = do
      ran <- subcommand argv root Nothing
      let stdout = fromUtf8 (nestedStdout ran)
          stderr = fromUtf8 (nestedStderr ran)
          status = case nestedExit ran of
            Just 0 -> "passed"
            Just 2 -> "incomplete"
            Just _ -> "failed"
            Nothing -> "incomplete"
      pure
        ( JObject
            ( [ ("status", JString status),
                ("exitCode", maybe JNull (integer . toInteger) (nestedExit ran)),
                either (const ("output", JString stdout)) (\value -> ("result", value)) (parseJson stdout)
              ]
                ++ [("detail", JString stderr) | not (null stderr)]
            )
        )

-- | project.mjs projectExitCode: 1 for a failed row or a refuted
-- obligation, 2 for an incomplete row or an obligation without a result,
-- otherwise 0.
projectExitCode :: Json -> Int
projectExitCode report
  | any (== Just (JString "failed")) statuses || any ((== Just (JString "refuted")) . member "status") rows = 1
  | any (== Just (JString "incomplete")) statuses || any ((`elem` map (Just . JString) ["unknown", "unsupported", "incomplete", "pending"]) . member "status") rows = 2
  | otherwise = 0
  where
    statuses = [member key report >>= member "status" | key <- ["canon", "definitions", "verification", "proof", "native"]]
    evidence = member "verification" report >>= member "evidence"
    rows = case evidence >>= member "obligations" of
      Just obligations -> fromMaybe [] (arrayOf obligations)
      Nothing -> fromMaybe [] (evidence >>= arrayOf)

-- | The version canon.yaml expects: /^canon:\s*["']?([\d.x]+)/m, else
-- /"canon"\s*:\s*"([\d.x]+)"/.
canonExpectedVersion :: String -> Maybe String
canonExpectedVersion config = firstJust (map keyed lineStarts) `orElse` firstJust (map quoted (suffixes config))
  where
    lineStarts = config : [rest | (c, rest) <- zip config (drop 1 (suffixes config)), lineTerminator c]
    keyed text = do
      rest <- stripPrefix' "canon:" text
      let afterSpace = dropWhile javascriptSpace rest
          afterQuote = case afterSpace of
            q : more | q `elem` ("\"'" :: String) -> more
            _ -> afterSpace
      nonEmpty (takeWhile versionCharacter afterQuote)
    quoted text = do
      rest <- stripPrefix' "\"canon\"" text
      afterColon <- stripPrefix' ":" (dropWhile javascriptSpace rest)
      value <- stripPrefix' "\"" (dropWhile javascriptSpace afterColon)
      let version = takeWhile versionCharacter value
      case drop (length version) value of
        '"' : _ | not (null version) -> Just version
        _ -> Nothing
    versionCharacter c = isDigit c || c == '.' || c == 'x'
    lineTerminator c = c `elem` ("\n\r\x2028\x2029" :: String)

-- | The version canon version reports: /canon\s+(\d+\.\d+\.\d+)/.
canonReportedVersion :: String -> Maybe String
canonReportedVersion output = firstJust (map at (suffixes output))
  where
    at text = do
      rest <- stripPrefix' "canon" text
      let (space, afterSpace) = span javascriptSpace rest
      if null space then Nothing else version afterSpace
    version text = do
      let (major, r1) = span isDigit text
      r1' <- if null major then Nothing else stripPrefix' "." r1
      let (minor, r2) = span isDigit r1'
      r2' <- if null minor then Nothing else stripPrefix' "." r2
      let patch = takeWhile isDigit r2'
      if null patch then Nothing else Just (major ++ "." ++ minor ++ "." ++ patch)

-- | JavaScript's \s: WhiteSpace and LineTerminator.
javascriptSpace :: Char -> Bool
javascriptSpace c = c `elem` ("\t\n\v\f\r \x00a0\x1680\x2028\x2029\x202f\x205f\x3000\xfeff" :: String) || (c >= '\x2000' && c <= '\x200a')

suffixes :: String -> [String]
suffixes text = case text of
  [] -> [[]]
  _ : rest -> text : suffixes rest

stripPrefix' :: String -> String -> Maybe String
stripPrefix' prefix text
  | prefix `isPrefixOf` text = Just (drop (length prefix) text)
  | otherwise = Nothing

nonEmpty :: String -> Maybe String
nonEmpty text = if null text then Nothing else Just text

firstJust :: [Maybe a] -> Maybe a
firstJust items = case [value | Just value <- items] of
  value : _ -> Just value
  [] -> Nothing

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just value) _ = Just value
orElse Nothing other = other
