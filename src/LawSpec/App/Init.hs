-- | @lawspec init@, ported from lawspec.mjs init() and prepare.mjs: adds a
-- target to lawspec.edn (creating the manifest and its starter
-- specification when there is none), writes the scaffold's build files
-- into a project that has none, adds the settings an existing JSON build
-- file lacks, and, unless --no-install, fetches the project's dependencies
-- with its own build tool and runs lawspec doctor. The compiler's scaffold
-- request names the project and renders its files; what to add and which
-- commands to run are "LawSpec.Scaffold"'s data.
-- ref:DEC-haskell-application-port ref:DEC-init-prepares-project
module LawSpec.App.Init
  ( initCommand,
    starterSpecification,
  )
where

import Control.Monad (filterM, foldM, forM, forM_, unless, when)
import Data.Either (isRight)
import Data.List (intercalate, isPrefixOf, isSuffixOf, sortBy)
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import LawSpec.App.Arguments hiding (present)
import LawSpec.App.Command
import LawSpec.App.Compiler (call)
import LawSpec.App.Doctor (doctor)
import LawSpec.App.Files (atomicWrite, compareUtf16, readOptional, safePath)
import LawSpec.App.Json
import LawSpec.App.Packages (toManifest)
import LawSpec.App.Process (Echo (..), Launch (..), Run (..), execTool, launch, runProcess)
import LawSpec.App.Project (readManifest)
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, relative, resolve)
import LawSpec.Manifest.EDN (writeManifest)
import LawSpec.Scaffold (PresentationCheck (..), generatedRootsAdvice, prepareCommands, scaffoldRequirements, setupAdvice)
import LawSpec.Targets (artifactTargets, targets)

-- | The build files whose presence marks an existing project.
buildFiles :: [String]
buildFiles =
  [ "Cargo.toml",
    "pom.xml",
    "pyproject.toml",
    "package.json",
    "go.mod",
    "stack.yaml",
    "package.yaml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle.kts",
    "rebar.config",
    "mix.exs",
    "gleam.toml"
  ]

-- | The files an existing project's name is read from.
nameFiles :: [String]
nameFiles = buildFiles ++ ["settings.gradle", "Package.swift"]

-- | A .cabal, .slnx or .sln file.
solutionFile :: String -> Bool
solutionFile name = any (`isSuffixOf` name) [".cabal", ".slnx", ".sln"]

-- | lawspec init's starter for an artifact target other than make.
configurationStarter :: String
configurationStarter =
  "unit configuration\ntype Settings is a record\n{\n  port :: UInt16\n  enabled :: Bool\n}\nend type\nfunction settings (unused :: Unit) -> Settings is Settings record{port = 8080,\n    enabled = true} end function\nend unit\n"

initCommand :: (Monad m) => Invocation -> Arguments -> Maybe Integer -> FilePath -> FilePath -> Command m Int
initCommand invocation arguments machineBits configFile configRoot = do
  let language = option "target" arguments
      minify = flag "minify" arguments
      projectOption = option "project" arguments
  name <- case language of
    Just chosen | chosen `elem` targets -> pure chosen
    _ -> failWith ("Choose --target " ++ intercalate "|" targets)
  unless (".edn" `isSuffixOf` baseName configFile && baseName configFile /= ".edn") $
    failWith "Use lawspec.edn; JSON configuration is no longer supported"
  forM_ ["lawspec.json", "lawspec-package.json"] $ \old -> do
    let path' = join configRoot old
    grantRead [path']
    existing <- readOptional path'
    when (isJust existing) (failWith (old ++ " is no longer supported; use lawspec.edn"))
  current <- readOptional configFile
  config0 <- case current of
    Nothing ->
      pure
        ( JObject
            [ ("manifestVersion", integer 1),
              ("component", JObject [("name", JString (baseName configRoot)), ("version", JString "0.1.0")]),
              ("languageProfile", JString "1.0-rc.2"),
              ("verification", JObject [("layers", JArray [])]),
              ("sources", JArray [JString "laws"]),
              ("targets", JArray [])
            ]
        )
    Just _ -> readManifest configFile
  let configured0 = targetsOf config0
      declared = [target | target <- configured0, language' target == name]
  when (isNothing projectOption && length declared > 1) $
    failWith ("Several " ++ name ++ " targets are configured; choose the root with --project")
  let root = resolve configRoot (fromMaybe "." (maybe (case declared of target : _ -> stringOf' "root" target; [] -> Nothing) Just projectOption))
      matches target = language' target == name && resolve configRoot (fromMaybe "undefined" (stringOf' "root" target)) == root
      configured = any matches configured0
  -- The manifest's directory and the target's root are project roots once
  -- they exist; a directory init is about to create is only a write root,
  -- which the guard lets it make.
  grantRead [root]
  present <- filterM (fmap isRight . effectOr . Stat Follow) [configRoot, root]
  grantProject present
  grantWrite [configRoot, root]
  makeDirectory root
  -- A Java target's build options, from the command line or the target the
  -- manifest already declares; the compiler checks them at generation.
  let javaOptions =
        [("release", maybe JNull (JNumber . fromRational) (javascriptNumber release)) | Just release <- [option "release" arguments]]
          ++ [("generatedSourceDir", JString directory) | Just directory <- [option "generated-source-dir" arguments]]
          ++ [("generatedTestDir", JString directory) | Just directory <- [option "generated-test-dir" arguments]]
      declaredTarget = case filter matches configured0 of
        target : _ -> Just target
        [] -> Nothing
      build = jsObject (maybe [] members declaredTarget ++ javaOptions)
  -- The compiler names the project and renders its build files; the host
  -- passes what it read. ref:DEC-scaffold-project-name
  listing <- listing' root
  let named = sortBy compareUtf16 [entry | entry <- listing, entry `elem` nameFiles || solutionFile entry]
  read' <- forM named $ \entry -> do
    let path' = join root entry
    fmap (\bytes -> (entry, fromUtf8 bytes)) . either (const Nothing) Just <$> effectOr (ReadFile path')
  let manifestName = case current of
        Nothing -> Nothing
        Just _ -> case member "component" config0 >>= member "name" of
          Just value -> Just value
          Nothing -> member "package" config0 >>= member "name"
      request =
        jsObject
          ( [ ("target", JString name),
              ("minify", JBool minify)
            ]
              ++ [("release", value) | Just value <- [member "release" build]]
              ++ [("name", JString value) | Just value <- [option "name" arguments]]
              ++ [("group", JString value) | Just value <- [option "group" arguments]]
              ++ [ ( "buildFiles",
                     JArray [JObject [("path", JString path'), ("content", JString content)] | (path', content) <- catMaybes read']
                   )
                 ]
              ++ [("manifestName", value) | Just value <- [manifestName]]
              ++ [("directory", JString (baseName configRoot))]
          )
  result <- call "scaffold" request
  case member "diagnostics" result >>= arrayOf of
    Just items@(_ : _) -> failWithDiagnostics (intercalate "\n" [maybe "undefined" jsString (member "message" item) | item <- items]) (JArray items)
    _ -> pure ()
  let scaffold = [(path', maybe "undefined" jsString (member "content" item)) | item <- fromMaybe [] (member "files" result >>= arrayOf), Just path' <- [stringOf' "path" item]]
      project = fromMaybe (JObject []) (member "project" result)
      config1 = case current of
        Nothing -> setPath ["component", "name"] (fromMaybe JNull (member "component" project)) config0
        Just _ -> config0
  -- A file init itself would write also marks the project as set up, so
  -- that running init again never stops on its own earlier output.
  scaffolded <- or <$> forM scaffold (\(path', _) -> isJust <$> readOptional (join root path'))
  hasBuild <- if scaffolded then pure True else any (\entry -> entry `elem` buildFiles || solutionFile entry) <$> listing' root
  let additions = if hasBuild then [] else scaffold
  forM_ additions $ \(path', _) -> do
    file <- safePath root path'
    existing <- readOptional file
    when (isJust existing) (failWith ("Will not overwrite " ++ file))
  starter <- safePath configRoot "laws/atoi_codec.lawspec"
  _ <- safePath configRoot (baseName configFile)
  when (isNothing current) $ do
    existing <- readOptional starter
    when (isJust existing) (failWith "Starter specification already exists; create lawspec.edn manually to use it")
  when (not hasBuild && name /= "go") (makeDirectory (join root "src"))
  forM_ additions $ \(path', content) -> atomicWrite (join root path') content True
  -- A project that already has build files keeps them; only the settings a
  -- JSON build file lacks are added. ref:DEC-init-prepares-project
  (created, updated) <-
    if hasBuild
      then applyRequirements name root scaffold
      else pure ([], [])
  when (isNothing current) $
    atomicWrite starter (if name `elem` artifactTargets && name /= "make" then configurationStarter else starterSpecification) True
  let config2 = maybe config1 (\bits -> setMember "machineBits" (integer bits) config1) machineBits
      config3 =
        if not configured
          then
            setMember
              "targets"
              (JArray (targetsOf config2 ++ [jsObject ([("language", JString name), ("root", JString (orDot (relative configRoot root)))] ++ javaOptions)]))
              config2
          else setMember "targets" (JArray [if matches target && Just target == declaredTarget then foldl (\t (k, v) -> setMember k v t) target javaOptions else target | target <- targetsOf config2]) config2
      manifestText config = writeManifest minify (toManifest config)
  when (isNothing current || not configured || isJust machineBits || not (null javaOptions)) $
    atomicWrite configFile (manifestText config3) (isNothing current)
  let changes = map ("created " ++) created ++ map ("updated " ++) updated
      roots = generatedRootsAdvice (stringOf' "generatedSourceDir" build) (stringOf' "generatedTestDir" build)
      projectSummary = case member "summary" project of
        Just value | isTruthy value && (not hasBuild || not (null created)) -> "\n" ++ jsString value
        _ -> ""
      summary =
        "Configured "
          ++ name
          ++ ". "
          ++ ( if hasBuild
                 then "Existing build files preserved" ++ (if null changes then "" else "; " ++ intercalate "; " changes) ++ "."
                 else "Created missing project build files."
             )
          ++ projectSummary
          ++ (if null roots then "" else "\nRegister the generated directories in the build:\n" ++ roots)
      setup = fromMaybe "undefined" (setupAdvice name)
  if flag "no-install" arguments
    then do
      printLine (summary ++ "\n" ++ setup ++ "\nNext: lawspec doctor, then lawspec generate.")
      pure 0
    else do
      let target0 = case filter matches (targetsOf config3) of
            target : _ -> target
            [] -> JObject []
      report <-
        recover
          ( do
              python <- prepareProject invocation target0 root (not configured)
              target <- case python of
                Nothing -> pure target0
                Just interpreter -> do
                  let target = setMember "python" (JString interpreter) target0
                      config4 = setMember "targets" (JArray [if matches t then target else t | t <- targetsOf config3]) config3
                  atomicWrite configFile (manifestText config4) False
                  pure target
              doctor target root []
          )
          (\problem -> pure (JObject [("ok", JBool False), ("message", JString (failureMessage problem)), ("instructions", JString setup)]))
      let text key = maybe "undefined" jsString (member key report)
          artifact = member "kind" report == Just (JString "artifact")
      if member "ok" report == Just (JBool True)
        then do
          printLine
            ( summary
                ++ "\n"
                ++ ( if artifact
                       then setup
                       else
                         if null (prepareCommands name)
                           then "lawspec doctor passes."
                           else "Dependencies are installed and lawspec doctor passes."
                   )
                ++ "\nNext: lawspec generate"
                ++ (if artifact then "" else ", then lawspec test")
                ++ "."
            )
          pure 0
        else do
          printLine
            ( summary
                ++ "\n"
                ++ name
                ++ " is not ready: "
                ++ text "message"
                ++ "\n"
                ++ text "instructions"
                ++ "\nCorrect this and run lawspec init --target "
                ++ name
                ++ " again, or lawspec doctor to check."
            )
          pure 1
  where
    language' target = maybe "" jsString (member "language" target)
    stringOf' key value = member key value >>= stringOf
    targetsOf config = fromMaybe [] (member "targets" config >>= arrayOf)
    orDot path' = if null path' then "." else path'
    listing' directory = map entryName <$> effect (nodeFailure "scandir" directory) (ListDirectory directory)

-- | mkdir -p. An existing directory is left alone, so the working
-- directory, which the guard protects, can be the project root.
makeDirectory :: (Monad m) => FilePath -> Command m ()
makeDirectory directory = do
  existing <- effectOr (Stat Follow directory)
  case existing of
    Right status | statusKind status == DirectoryKind -> pure ()
    _ -> effect (nodeFailure "mkdir" directory) (MakeDirectories Nothing directory)

baseName :: FilePath -> String
baseName = reverse . takeWhile (/= '/') . reverse . dropTrailing
  where
    dropTrailing path' = if length path' > 1 && "/" `isSuffixOf` path' then init path' else path'

-- | object.a.b = value along a path of existing objects.
setPath :: [String] -> Json -> Json -> Json
setPath keys value document = case keys of
  [] -> value
  [leaf] -> setMember leaf value document
  key : rest -> setMember key (setPath rest value (fromMaybe (JObject []) (member key document))) document

-- | prepare.mjs applyRequirements: the files created from the scaffold and
-- the settings added to existing JSON files.
applyRequirements :: (Monad m) => String -> FilePath -> [(FilePath, String)] -> Command m ([String], [String])
applyRequirements language root scaffold =
  foldM step ([], []) (scaffoldRequirements language)
  where
    step (created, updated) (file, entries) = do
      target <- safePath root file
      text <- readOptional target
      case text of
        Nothing -> do
          atomicWrite target (fromMaybe "undefined" (lookup file scaffold)) True
          pure (created ++ [file], updated)
        Just _ | null entries -> pure (created, updated)
        Just content -> do
          document <- case parseJson content of
            Left _ -> failWith (file ++ " is not valid JSON, so lawspec init cannot update it")
            Right value@(JObject _) -> pure value
            Right _ -> failWith (file ++ " must hold a JSON object")
          (document', changed) <- foldM (applyEntry language root file) (document, []) entries
          if null changed
            then pure (created, updated)
            else do
              let indent = case [takeWhile (`elem` (" \t" :: String)) line | line <- lines' content, let spaces = takeWhile (`elem` (" \t" :: String)) line, not (null spaces), "\"" `isPrefixOf` drop (length spaces) line] of
                    found : _ -> found
                    [] -> if '\n' `elem` content then "  " else ""
              atomicWrite target (stringifyWith indent document' ++ (if "\n" `isSuffixOf` content then "\n" else "")) False
              pure (created, updated ++ [file ++ " (" ++ intercalate ", " changed ++ ")"])
    -- The lines /^...$/m sees: split at \n, \r, U+2028 and U+2029.
    lines' text = case break (`elem` ("\n\r\x2028\x2029" :: String)) text of
      (line, []) -> [line]
      (line, _ : rest) -> line : lines' rest

-- | prepare.mjs applyEntries for one setting: each missing holder becomes an
-- object first, then the setting is added when it is missing, or when it is
-- npm init's type=commonjs and no source depends on it.
applyEntry :: (Monad m) => String -> FilePath -> FilePath -> (Json, [String]) -> ([String], String) -> Command m (Json, [String])
applyEntry language root file (document, changed) (keys, value) = do
  let holders = init keys
      leaf = last keys
      label = intercalate "." keys
  document' <- foldM ensure document (drop 1 (scanl (\prefix key -> prefix ++ [key]) [] holders))
  let holder = foldl (\current key -> fromMaybe JNull (member key current)) document' holders
      dependency = member "dependencies" document' >>= member leaf
  if take 1 keys == ["devDependencies"] && maybe False isTruthy dependency
    then pure (document', changed)
    else case member leaf holder of
      Nothing -> pure (setPath keys (JString value) document', changed ++ [label])
      Just (JString "commonjs") | label == "type" -> do
        script <- firstScript root ""
        forM_ script $ \found ->
          failWith (file ++ " sets type=commonjs and " ++ found ++ " depends on it. LawSpec's " ++ language ++ " target needs type=module: convert the project to ES modules, or give the target its own directory with --project <directory>.")
        pure (setPath keys (JString value) document', changed ++ [label])
      Just _ -> pure (document', changed)
  where
    ensure current path' = do
      let parent = foldl (\here step -> fromMaybe JNull (member step here)) current (init path')
          key = last path'
      case member key parent of
        Just (JObject _) -> pure current
        Just JNull -> pure (setPath path' (JObject []) current)
        Nothing -> pure (setPath path' (JObject []) current)
        Just _ -> failWith (file ++ ": " ++ key ++ " must be an object")

-- | The first CommonJS-by-default source in the project, if it has one.
firstScript :: (Monad m) => FilePath -> FilePath -> Command m (Maybe FilePath)
firstScript root folder = do
  let directory = if null folder then root else join root folder
  entries <- effect (nodeFailure "scandir" directory) (ListDirectory directory)
  foldM
    ( \found entry -> case found of
        Just _ -> pure found
        Nothing -> do
          let relative' = if null folder then entryName entry else folder ++ "/" ++ entryName entry
          case entryKind entry of
            DirectoryKind
              | "." `isPrefixOf` entryName entry || entryName entry `elem` ["node_modules", "dist", "build", "target", "coverage"] -> pure Nothing
              | otherwise -> firstScript root relative'
            _
              | any (`isSuffixOf` entryName entry) [".js", ".jsx", ".ts", ".tsx"] -> pure (Just relative')
              | otherwise -> pure Nothing
    )
    Nothing
    entries

-- | prepare.mjs prepareProject: fetches the project's dependencies with
-- its build tool; for a Python target init is adding without an
-- interpreter, the environment it created, for the manifest.
prepareProject :: (Monad m) => Invocation -> Json -> FilePath -> Bool -> Command m (Maybe String)
prepareProject invocation target root added = do
  let commands = prepareCommands (maybe "" jsString (member "language" target))
      usesPython = any ((== "{python}") . checkCommand) commands
      declaredPython = member "python" target >>= stringOf
  python <-
    if usesPython && added && isNothing declaredPython
      then Just <$> projectPython invocation root
      else pure Nothing
  forM_ commands $ \step -> do
    command <-
      if checkCommand step == "{python}"
        then pure (fromMaybe "python3" (maybe python Just declaredPython))
        else toolFor (checkCommand step) target root
    runTool command (checkArguments step) root (checkEnvironment step)
  pure python

-- | A project without a chosen interpreter gets its own virtual environment.
projectPython :: (Monad m) => Invocation -> FilePath -> Command m String
projectPython invocation root = do
  let relative' = ".venv/bin/python"
      interpreter = join root relative'
  grantRead [interpreter]
  exists <- either (const False) (const True) <$> effectOr (Stat Follow interpreter)
  unless exists $ do
    found <- findPython invocation
    runTool found ["-m", "venv", ".venv"] root []
  pure relative'

-- | The first interpreter on PATH that is new enough for the Python targets.
findPython :: (Monad m) => Invocation -> Command m String
findPython invocation = go ["python3", "python3.14", "python3.13", "python"]
  where
    go [] = failWith "Python 3.13 or later was not found on PATH"
    go (candidate : rest) = do
      answer <- execTool (launch candidate ["-c", "import sys; print(sys.version_info[:2] >= (3, 13))"] (invocationDirectory invocation))
      case answer of
        Right text | trim text == "True" -> pure candidate
        _ -> go rest
    trim = reverse . dropWhile (`elem` (" \t\n\r" :: String)) . reverse . dropWhile (`elem` (" \t\n\r" :: String))

-- | prepare.mjs toolFor: the manifest field naming a target's build tool,
-- the Gradle wrapper, or the command itself.
toolFor :: (Monad m) => String -> Json -> FilePath -> Command m String
toolFor command target root
  | command == "gradle" = case member "gradle" target of
      Just value | isTruthy value -> pure (jsString value)
      _ -> do
        let wrapper = join root "gradlew"
        grantRead [wrapper]
        exists <- either (const False) (const True) <$> effectOr (Stat Follow wrapper)
        pure (if exists then wrapper else "gradle")
  | otherwise = pure $ case lookup command overrides >>= \field -> member field target of
      Just value | isTruthy value -> jsString value
      _ -> command
  where
    overrides = [("mvn", "maven"), ("gradle", "gradle"), ("cargo", "cargo"), ("scala", "scala"), ("clojure", "clojure"), ("swift", "swift")]

-- | prepare.mjs runTool: the tool's output on standard error, so that
-- standard output stays init's own.
runTool :: (Monad m) => String -> [String] -> FilePath -> [(String, String)] -> Command m ()
runTool command arguments directory environment = do
  run <- runProcess (launch command arguments directory) {launchEnvironment = [(key, Just value) | (key, value) <- environment], launchEcho = EchoTo Stderr}
  let shown = unwords (command : arguments)
  case (runError run, runExit run) of
    (Just message, _) -> failWith message
    (_, Just (ExitCode 0)) -> pure ()
    (_, Just (ExitCode code)) -> failWith (shown ++ " exited with " ++ show code)
    (_, _) -> failWith (shown ++ " exited with null")

-- | templates/npm/starter-rc1.lawspec, the starter specification lawspec
-- init writes for a program target (PackagesSpec compares the two).
starterSpecification :: String
starterSpecification =
  "unit example.codec\n"
    ++ "\n"
    ++ "itoa of type Int32 -> Text\n"
    ++ "atoi of type Text -> Int32\n"
    ++ "\n"
    ++ "law codec is\n"
    ++ "  description:\n"
    ++ "    \"Converting an integer to decimal text and reading it back preserves it.\"\n"
    ++ "  end description\n"
    ++ "\n"
    ++ "  definition:\n"
    ++ "    for all (x of type Int32) =>\n"
    ++ "      atoi (itoa x) must be x\n"
    ++ "    end for all\n"
    ++ "  end definition\n"
    ++ "\n"
    ++ "  expect itoa x = encoded\n"
    ++ "  expect atoi encoded = x\n"
    ++ "  in table (x, encoded):\n"
    ++ "    row -42, \"-42\"\n"
    ++ "    row 0, \"0\"\n"
    ++ "    row 42, \"42\"\n"
    ++ "  end table\n"
    ++ "end law\n"
    ++ "end unit\n"
