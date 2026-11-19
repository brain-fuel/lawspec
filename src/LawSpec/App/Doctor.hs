-- | lawspec doctor: the Node CLI's doctor.mjs and beam-doctor.mjs, ported.
-- Each program target's toolchain is probed through spawned processes (its
-- compiler, build tool and test libraries), and the versions found are
-- compared with the verified compatibility profiles. The probes that must
-- run inside a toolchain (Python, Gradle's init script, the BEAM escript
-- and Mix script, TypeScript's configuration reader) print facts as JSON;
-- every decision about them is made here.
--
-- A report is the legacy one: the target, ok, the versions found (and the
-- BEAM coverage settings), or the first failed requirement with the
-- target's setup advice. Where the legacy CLI checked the Node that ran it
-- (Node 22+), the core checks the node a JavaScript or TypeScript target's
-- tests run with, since a host need not be Node.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Doctor
  ( doctor,
    doctorCommand,
    probeCache,
    compatibility,
    supported,
    satisfiesRequirement,
    beamDoctorRuntime,
    temporaryDirectory,
  )
where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import qualified Data.ByteString as B
import Data.Char (isDigit, isSpace)
import Data.List (find, intercalate, isInfixOf, isPrefixOf, isSuffixOf, tails)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import LawSpec.App.BeamProbes (elixirProbe, erlangProbe)
import LawSpec.App.Command
import LawSpec.App.Json
import LawSpec.App.Process
import LawSpec.App.Project (CacheLocation (..))
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, normalise, resolve, takeDirectory)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Scaffold (generatedRootsAdvice, setupAdvice)
import LawSpec.TargetOptions (defaultJavaRelease, javaReleases)
import LawSpec.Targets (artifactTargets)

-- | The verified compatibility profiles (npm/compatibility.json, which an
-- Hspec test keeps equal): each target's dependencies, in order, with the
-- lowest admitted version and the first version above the range.
compatibility :: [(String, [(String, (String, String))])]
compatibility =
  [ ("java", [("java", ("21", "26")), ("jetCheck", ("0.3.0", "0.3.1")), ("junit-jupiter", ("5.14.0", "6.1.0"))]),
    ("python", [("python", ("3.13", "3.15")), ("pytest", ("8.4.0", "8.5.0")), ("hypothesis", ("6.135.26", "7"))]),
    ("javascript", [("fast-check", ("4", "5"))]),
    ("typescript", [("fast-check", ("4", "5")), ("typescript", ("5.9", "5.10")), ("@types/node", ("22", "23"))]),
    ("go", [("go", ("1.22", "1.27")), ("rapid", ("1.2.0", "1.4.0"))]),
    ("haskell", [("hspec", ("2.11", "2.12")), ("hedgehog", ("1.5", "1.6")), ("hspec-hedgehog", ("0.3.0.0", "0.3.0.1")), ("ghc", ("9.10", "9.11"))]),
    ("kotlin", [("java", ("25", "26")), ("gradle", ("9.1", "9.4")), ("kotlin", ("2.3.21", "2.3.22"))]),
    ("scala", [("java", ("25", "27")), ("scala-cli", ("1.16", "1.17")), ("scala", ("3.9", "3.11")), ("scalacheck", ("1.20.0", "1.21")), ("scalatest", ("3.2.20", "3.3"))]),
    ("clojure", [("java", ("25", "26")), ("clojure", ("1.12", "1.13")), ("test.check", ("1.1.3", "1.2"))]),
    ("groovy", [("java", ("25", "26")), ("gradle", ("9.1", "9.4")), ("groovy", ("5.0", "5.1")), ("spock", ("2.5", "2.6"))]),
    ("erlang", [("otp", ("29", "30")), ("rebar3", ("3.27.1", "3.28")), ("proper", ("1.5.0", "1.5.1"))]),
    ("elixir", [("otp", ("29", "30")), ("elixir", ("1.20", "1.21")), ("stream_data", ("1.4.0", "1.4.1"))]),
    ("gleam", [("otp", ("29", "30")), ("gleam", ("1.18", "1.20")), ("gleam_stdlib", ("1.0.5", "1.0.6")), ("gleeunit", ("1.11.0", "1.11.1")), ("qcheck", ("1.0.5", "1.0.6"))]),
    ("rust", [("rust", ("1.85", "2")), ("proptest", ("1.11.0", "1.11.1")), ("num-bigint", ("0.4.8", "0.4.9")), ("num-rational", ("0.4.2", "0.4.3")), ("num-complex", ("0.4.6", "0.4.7")), ("num-traits", ("0.2.19", "0.2.20"))]),
    ("fsharp", [("dotnet", ("10", "11")), ("xunit.v3", ("4.0.2", "4.1"))]),
    ("csharp", [("dotnet", ("10", "11")), ("xunit.v3", ("4.0.2", "4.1"))]),
    ("swift", [("swift", ("6.2", "6.4"))])
  ]

-- | Version parts as doctor.mjs compares them: Number() of each part, where
-- an empty part is 0 and a part that is not a number (NaN) counts as 0 too.
versionParts :: String -> [Integer]
versionParts text = map part (splitOn '.' (dropV text))
  where
    dropV ('v' : rest) = rest
    dropV other = other
    part piece = if not (null piece) && all isDigit piece then read piece else 0

compareVersions :: String -> String -> Int
compareVersions a b = go (versionParts a) (versionParts b)
  where
    go [] [] = 0
    go xs ys =
      let (x, xs') = uncons' xs
          (y, ys') = uncons' ys
       in if x /= y then (if x > y then 1 else -1) else go xs' ys'
    uncons' [] = (0, [])
    uncons' (z : zs) = (z, zs)

-- | doctor.mjs supported(): a plain dotted version inside the target's range.
supported :: String -> String -> Maybe String -> Bool
supported target dependency version = case (lookup target compatibility >>= lookup dependency, version) of
  (Just (low, high), Just text) -> plain text && compareVersions text low >= 0 && compareVersions text high < 0
  _ -> False
  where
    plain text =
      let digits = case text of
            'v' : rest -> rest
            _ -> text
       in not (null digits) && all (\part -> not (null part) && all isDigit part) (splitOn '.' digits)

splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitOn separator rest

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- | Number(String(version).replace(/^v/, '').split('.')[0]).
major :: String -> Maybe Integer
major text = case takeWhile (/= '.') (case text of 'v' : rest -> rest; _ -> text) of
  digits | not (null digits), all isDigit digits -> Just (read digits)
  "" -> Just 0
  _ -> Nothing

atLeast :: Maybe String -> Integer -> Bool
atLeast version minimum' = maybe False (>= minimum') (version >>= major)

-- | A probe of one target: fails with the first unmet requirement.
type Probe m = ExceptT String (Command m)

require :: (Monad m) => Bool -> String -> Probe m ()
require condition message = unless condition (throwE message)

-- | doctor.mjs run(): a tool's standard output without ANSI colours, or
-- execFile's failure (a missing tool is spawn.mjs's not-found message).
run :: (Monad m) => FilePath -> [(String, Maybe String)] -> String -> [String] -> Probe m String
run root environment command arguments = do
  result <- lift (execTool (launch command arguments root) {launchEnvironment = environment, launchTimeout = Just 120000})
  either throwE (pure . withoutColours) result
  where
    withoutColours text = case text of
      '\ESC' : '[' : rest -> withoutColours (drop 1 (dropWhile (\c -> isDigit c || c == ';') rest) `orIfNot` rest)
      c : rest -> c : withoutColours rest
      [] -> []
    -- \x1b\[[0-9;]*m: only a sequence that ends in m is removed.
    orIfNot after rest = if take 1 (dropWhile (\c -> isDigit c || c == ';') rest) == "m" then after else '\ESC' : '[' : rest

-- | readFile(file, 'utf8'), failing with Node's message.
readText :: (Monad m) => FilePath -> Probe m String
readText file = do
  lift (grantRead [file])
  lift (effectOr (ReadFile file)) >>= either (throwE . failureMessage . nodeFailure "open" file) (pure . fromUtf8)

readMaybe' :: (Monad m) => FilePath -> Probe m (Maybe String)
readMaybe' file = do
  lift (grantRead [file])
  either (const Nothing) (Just . fromUtf8) <$> lift (effectOr (ReadFile file))

listNames :: (Monad m) => FilePath -> Probe m (Maybe [String])
listNames folder = do
  lift (grantRead [folder])
  either (const Nothing) (Just . map entryName) <$> lift (effectOr (ListDirectory folder))

exists :: (Monad m) => FilePath -> Probe m Bool
exists file = do
  lift (grantRead [file])
  either (const False) (const True) <$> lift (effectOr (Stat Follow file))

parse :: (Monad m) => String -> Probe m Json
parse text = either throwE pure (parseJson text)

-- | mkdtemp(prefix) in a lawspec-scratch folder of os.tmpdir(): a new
-- directory, writable. The folder, not the temporary root, is the write
-- root, so that the guard lets 'removeTree' remove the new directory, which
-- lies strictly inside it; the temporary root itself is protected.
temporaryDirectory :: (Monad m) => String -> Command m FilePath
temporaryDirectory prefix = do
  variable <- either (const Nothing) id <$> effectOr (GetEnvironment "TMPDIR")
  clock <- either (const (Clock 0 0)) id <$> effectOr GetClock
  let base = join (normalise (case variable of Just (d : ds) -> d : ds; _ -> "/tmp")) "lawspec-scratch"
      stem = join base (prefix ++ suffix (monotonicMicroseconds clock + wallMilliseconds clock))
  grantWrite [base]
  effect (nodeFailure "mkdir" base) (MakeDirectories Nothing base)
  -- Only a definite NotFound makes the name free: the directory is removed
  -- afterwards, so it must be one this run made.
  taken <- effectOr (Stat NoFollow stem)
  case taken of
    Left problem | errorKind problem == NotFound -> stem <$ effect (nodeFailure "mkdtemp" stem) (MakeDirectories Nothing stem)
    Right _ -> temporaryDirectory (prefix ++ "x")
    Left problem -> abort (nodeFailure "mkdtemp" stem problem)
  where
    alphabet = ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9']
    suffix n = take 6 [alphabet !! fromInteger ((n `div` (62 ^ i)) `mod` 62) | i <- [0 :: Integer ..]]

removeTree :: (Monad m) => FilePath -> Command m ()
removeTree folder = () <$ effectOr (Remove Recursive folder)

-- | Each verified dependency's version against its range.
checkProfile :: (Monad m) => String -> [(String, Json)] -> Probe m ()
checkProfile name versions =
  forM_ (fromMaybe [] (lookup name compatibility)) $ \(dependency, (low, high)) -> do
    let found = lookup dependency versions >>= versionText
    require
      (supported name dependency found)
      (dependency ++ " " ++ fromMaybe "(unknown)" found ++ " is outside the verified " ++ name ++ " profile [" ++ low ++ ", " ++ high ++ ")")
  where
    versionText value = if isTruthy value then Just (jsString value) else Nothing

language :: Json -> String
language target = maybe "" jsString (member "language" target)

field :: String -> Json -> Maybe String
field key target = member key target >>= stringOf

-- | doctor(target, root, plannedArtifacts): the target's report.
doctor :: (Monad m) => Json -> FilePath -> [Json] -> Command m Json
doctor target root planned
  | name `elem` artifactTargets =
      pure (JObject [("target", JString name), ("ok", JBool True), ("versions", JObject []), ("kind", JString "artifact"), ("instructions", instructions)])
  | otherwise = do
      grantRead [root]
      outcome <- runExceptT (probe name target root planned sourceDir testDir)
      pure $ case outcome of
        Right (versions, coverage) ->
          JObject ([("target", JString name), ("ok", JBool True), ("versions", jsObject versions)] ++ [("coverage", c) | Just c <- [coverage]])
        Left message ->
          JObject [("target", JString name), ("ok", JBool False), ("message", JString (take 4000 message)), ("instructions", instructions)]
  where
    name = language target
    instructions = maybe JNull JString (setupAdvice name)
    defaults = case name of
      "java" -> ("src/main/java", "src/test/java")
      "kotlin" -> ("src/main/kotlin", "src/test/kotlin")
      "scala" -> ("src/main/scala", "src/test/scala")
      "groovy" -> ("src/main/groovy", "src/test/groovy")
      "clojure" -> ("src", "test")
      _ -> ("src", if name `elem` ["python", "prolog", "rust", "fsharp", "csharp", "swift"] then "tests" else "test")
    sourceDir = fromMaybe (fst defaults) (field "sourceDir" target)
    testDir = fromMaybe (snd defaults) (field "testDir" target)

probe :: (Monad m) => String -> Json -> FilePath -> [Json] -> String -> String -> Probe m ([(String, Json)], Maybe Json)
probe name target root planned sourceDir testDir = do
  (versions, coverage) <- case name of
    _ | name `elem` ["javascript", "typescript"] -> javascript name target root sourceDir testDir
    _ | name `elem` ["python", "prolog"] -> python name target root sourceDir testDir
    "go" -> plain (goToolchain root)
    "haskell" -> plain (haskell root sourceDir testDir)
    "java" -> plain (java target root planned sourceDir testDir)
    "rust" -> plain (rust target root planned sourceDir testDir)
    "kotlin" -> plain (kotlin target root sourceDir testDir)
    "scala" -> plain (scala target root sourceDir testDir)
    "clojure" -> plain (clojure target root)
    "groovy" -> plain (groovy target root sourceDir testDir)
    _ | name `elem` ["fsharp", "csharp"] -> plain (dotnet name target root sourceDir testDir)
    "swift" -> plain (swift target root)
    _ | name `elem` ["erlang", "elixir", "gleam"] -> beam name target root planned
    _ -> throwE ("Unsupported target " ++ name)
  checkProfile name versions
  pure (versions, coverage)
  where
    plain step = (\versions -> (versions, Nothing)) <$> step

-- | Merge versions as Object.assign does: a known key keeps its place.
assign :: [(String, Json)] -> [(String, Json)] -> [(String, Json)]
assign = foldl (\kept (key, value) -> if any ((== key) . fst) kept then [(k, if k == key then value else v) | (k, v) <- kept] else kept ++ [(key, value)])

-- | require.resolve(name) from the project's package.json, then the
-- package.json above it that names the package (doctor.mjs installed()).
-- Node's resolution looks in node_modules from the project upwards.
installed :: (Monad m) => FilePath -> String -> Probe m String
installed root package = do
  let folders = takeWhileDistinct (iterate takeDirectory root)
      candidates = [join folder ("node_modules/" ++ package ++ "/package.json") | folder <- folders]
  found <- firstJust candidates
  case found of
    Nothing -> throwE ("Cannot find module '" ++ package ++ "'\nRequire stack:\n- " ++ join root "package.json")
    Just document -> case member "version" document of
      Just (JString version) -> pure version
      _ -> throwE ("Cannot resolve installed " ++ package)
  where
    takeWhileDistinct (a : b : rest) | a == b = [a] | otherwise = a : takeWhileDistinct (b : rest)
    takeWhileDistinct other = other
    firstJust [] = pure Nothing
    firstJust (file : more) = do
      text <- readMaybe' file
      case text >>= either (const Nothing) Just . parseJson of
        Just document | member "name" document == Just (JString package) -> pure (Just document)
        _ -> firstJust more

-- | TypeScript's own reading of tsconfig.json, run by the project's node
-- with the project's typescript, printed as facts.
typescriptFacts :: String
typescriptFacts =
  "const {createRequire}=require('node:module');const path=require('node:path');const root=process.cwd();"
    ++ "const req=createRequire(path.join(root,'package.json'));const ts=req('typescript');"
    ++ "const read=ts.readConfigFile(path.join(root,'tsconfig.json'),ts.sys.readFile);"
    ++ "if(read.error){console.log(JSON.stringify({readError:true}));}else{"
    ++ "const config=ts.parseJsonConfigFileContent(read.config,ts.sys,root);"
    ++ "console.log(JSON.stringify({readError:false,valid:config.errors.every(e=>e.code===18003),"
    ++ "layout:config.options.module===ts.ModuleKind.NodeNext&&config.options.outDir===path.join(root,'dist')&&config.options.rootDir===root,"
    ++ "emits:!config.options.noEmit&&config.options.target>=ts.ScriptTarget.ES2022,"
    ++ "include:config.raw.include??null,exclude:config.raw.exclude??null}));}"

javascript :: (Monad m) => String -> Json -> FilePath -> String -> String -> Probe m ([(String, Json)], Maybe Json)
javascript name _ root sourceDir testDir = do
  nodeVersion <- trim <$> run root [] "node" ["--version"]
  require (atLeast (Just nodeVersion) 22) "Node 22+ is required"
  pkg <- readText (join root "package.json") >>= parse
  require (member "type" pkg == Just (JString "module")) "package.json must specify type=module"
  fastCheck <- installed root "fast-check"
  require ("4." `isPrefixOf` fastCheck) "fast-check 4.x is required"
  if name /= "typescript"
    then pure ([("fast-check", JString fastCheck)], Nothing)
    else do
      typescript <- installed root "typescript"
      require ("5.9." `isPrefixOf` typescript) "TypeScript 5.9.x is required"
      facts <- run root [] "node" ["-e", typescriptFacts] >>= parse
      require (member "readError" facts == Just (JBool False)) "Cannot read tsconfig.json"
      require (member "valid" facts == Just (JBool True)) "Invalid TypeScript configuration"
      require (member "layout" facts == Just (JBool True)) "TypeScript requires module=NodeNext, rootDir=., outDir=dist"
      require (member "emits" facts == Just (JBool True)) "TypeScript requires emission and target ES2022+"
      let listed key = [text | Just (JArray values) <- [member key facts], JString text <- values]
      require
        ((sourceDir ++ "/**/*.ts") `elem` listed "include" && (testDir ++ "/**/*.ts") `elem` listed "include")
        "TypeScript must include the configured source and test directories"
      require
        (member "exclude" facts `elem` [Nothing, Just JNull] || all (`elem` ["node_modules", "dist"]) (listed "exclude"))
        "Custom TypeScript exclusions cannot be verified"
      types <- installed root "@types/node"
      require (atLeast (Just types) 22) "@types/node 22+ is required"
      pure ([("fast-check", JString fastCheck), ("typescript", JString typescript), ("@types/node", JString types)], Nothing)

pythonScript :: String
pythonScript = "import sys,json,importlib.metadata as m,tomllib,pathlib\np=tomllib.loads(pathlib.Path('pyproject.toml').read_text())\nprint(json.dumps({'python':'.'.join(map(str,sys.version_info[:3])),'optimization':sys.flags.optimize,'pytest':m.version('pytest'),'hypothesis':m.version('hypothesis'),'config':p.get('tool',{}).get('pytest',{}).get('ini_options',{})}))"

prologProbe :: String
prologProbe = "import json,importlib.metadata as m,janus_swi as j; v=j.query_once('current_prolog_flag(version_data,swi(Major,Minor,Patch,_)),use_module(library(plunit)),current_prolog_flag(determinism_error,error)'); print(json.dumps({'janus':m.version('janus-swi'),'swi':[v['Major'],v['Minor'],v['Patch']],'ready':v['truth']}))"

python :: (Monad m) => String -> Json -> FilePath -> String -> String -> Probe m ([(String, Json)], Maybe Json)
python name target root sourceDir testDir = do
  let interpreter = fromMaybe "python3" (field "python" target)
  facts <- run root [] interpreter ["-c", pythonScript] >>= parse
  let text key = maybe "" jsString (member key facts)
      version = text "python"
      config = fromMaybe (JObject []) (member "config" facts)
      listIncludes key wanted = case member key config of
        Just (JArray values) -> JString wanted `elem` values
        Just (JString value) -> wanted `isInfixOf` value
        _ -> False
  require (major version == Just 3 && maybe False (>= 13) (minorOf version)) "Python 3.13+ is required"
  require ("8.4." `isPrefixOf` text "pytest" && "6." `isPrefixOf` text "hypothesis") "pytest 8.4.x and Hypothesis 6.x are required"
  require (listIncludes "pythonpath" sourceDir && listIncludes "testpaths" testDir) "pytest must include the configured source and test directories"
  require
    (not (any (\key -> maybe False isTruthy (member key config)) ["addopts", "python_files", "python_functions"]))
    "Custom pytest selection options cannot be verified"
  addopts <- lift (either (const Nothing) id <$> effectOr (GetEnvironment "PYTEST_ADDOPTS"))
  require (maybe True null addopts) "Clear PYTEST_ADDOPTS before compatibility checks"
  let versions = [(key, value) | (key, value) <- members facts, key /= "config"]
  if name /= "prolog"
    then pure (versions, Nothing)
    else do
      require (member "optimization" facts == Just (integer 0)) "Prolog host tests require enabled Python assertions; remove -O/PYTHONOPTIMIZE"
      prolog <- run root [] interpreter ["-c", prologProbe] >>= parse
      require
        (member "janus" prolog == Just (JString "1.5.3") && (member "swi" prolog >>= arrayOf >>= listToMaybe) == Just (integer 10) && member "ready" prolog == Just (JBool True))
        "Prolog requires janus-swi 1.5.3, SWI-Prolog 10.x, PLUnit and determinism guards"
      pure (assign versions (members prolog), Nothing)
  where
    minorOf version = case splitOn '.' version of
      _ : minor : _ | not (null minor), all isDigit minor -> Just (read minor :: Integer)
      _ -> Nothing

-- | The first match of a prefix followed by a dotted version with between
-- the given numbers of further parts.
versionAfter :: String -> Int -> Int -> String -> Maybe String
versionAfter prefix fewest most text = listToMaybe [version | rest <- tails text, prefix `isPrefixOf` rest, Just version <- [dotted (drop (length prefix) rest)]]
  where
    dotted input =
      let (first, more) = span isDigit input
       in if null first then Nothing else parts first more (0 :: Int)
    parts kept input count = case input of
      '.' : more
        | count < most,
          (digits@(_ : _), rest) <- span isDigit more ->
            parts (kept ++ "." ++ digits) rest (count + 1)
      _ -> if count >= fewest then Just kept else Nothing

goToolchain :: (Monad m) => FilePath -> Probe m [(String, Json)]
goToolchain root = do
  version <- versionAfter "go" 1 2 <$> run root [] "go" ["version"]
  require (maybe False (\v -> maybe False (>= 22) (minorOf v)) version) "Go 1.22+ is required"
  let local = [("GOTOOLCHAIN", Just "local"), ("GOFLAGS", Just "")]
  rapid <- run root local "go" ["list", "-mod=readonly", "-m", "-json", "pgregory.net/rapid"] >>= parse
  let rapidVersion = member "Version" rapid >>= stringOf
  require
    (not (maybe False isTruthy (member "Replace" rapid)) && supported "go" "rapid" rapidVersion)
    "Stable Rapid >=1.2.0 <1.4.0 without local replacement is required"
  _ <- run root local "go" ["list", "-mod=readonly", "pgregory.net/rapid"]
  pure ([("go", maybe JNull JString version), ("rapid", maybe JNull JString rapidVersion)])
  where
    minorOf v = case splitOn '.' v of
      _ : minor : _ | all isDigit minor, not (null minor) -> Just (read minor :: Integer)
      _ -> Nothing

-- | stack's --with-hpack hook as doctor.mjs's read-only-hpack.mjs: it
-- reports hpack's version and refuses to write a .cabal file.
readOnlyHpack :: String
readOnlyHpack =
  "#!/bin/sh\ncase \" $* \" in *\" --numeric-version \"*|*\" --version \"*) echo 0.38.1; exit 0;; esac\n"
    ++ "for f in ./*.cabal; do [ -e \"$f\" ] && exit 0; done\n"
    ++ "echo 'LawSpec doctor requires an existing .cabal file. Run stack build --test --no-run-tests first.' >&2\nexit 1\n"

haskell :: (Monad m) => FilePath -> String -> String -> Probe m [(String, Json)]
haskell root sourceDir testDir = do
  names <- fromMaybe [] <$> listNames root
  let cabals = filter (".cabal" `isSuffixOf`) names
  require
    (not (null cabals))
    ("The Haskell project in " ++ root ++ " has no .cabal file yet. Run `stack build --test --no-run-tests` there once, then try again")
  scratch <- lift (temporaryDirectory "lawspec-hpack-")
  let hook = join scratch "read-only-hpack"
  _ <- lift (effectOr (WriteFile Replace Nothing hook (utf8 readOnlyHpack)))
  lift (grantPrograms [hook])
  result <- lift . runExceptT $ do
    _ <- run root [] "/bin/chmod" ["+x", hook]
    compiler <- trim <$> run root [] "stack" ["--no-terminal", "--no-install-ghc", "--with-hpack", hook, "--lock-file", "read-only", "path", "--compiler-exe"]
    present <- exists compiler
    require present ("ENOENT: no such file or directory, access '" ++ compiler ++ "'")
    ghc <- trim <$> run root [] compiler ["--numeric-version"]
    dependencies <- run root [] "stack" ["--no-terminal", "--with-hpack", hook, "--lock-file", "read-only", "ls", "dependencies", "json", "--test", "--global-hints"] >>= parse
    pure (ghc, dependencies)
  lift (removeTree scratch)
  (ghc, dependencies) <- either throwE pure result
  let versions = assign [("ghc", JString ghc)] [(jsString name', version) | entry <- fromMaybe [] (arrayOf dependencies), Just name' <- [member "name" entry], Just version <- [member "version" entry]]
      versionOf key = lookup key versions
  forM_ ["hspec", "hedgehog", "hspec-hedgehog", "hspec-discover"] $ \dependency ->
    require (maybe False isTruthy (versionOf dependency)) ("Stack test plan is missing " ++ dependency)
  require (maybe False isTruthy (versionOf "network")) "Stack plan is missing network (a library dependency, for distribution)"
  let starts prefix key = maybe False (isPrefixOf prefix . jsString) (versionOf key)
  require (starts "2.11." "hspec" && starts "1." "hedgehog" && starts "0.3." "hspec-hedgehog") "Unsupported Hspec/Hedgehog combination; use lts-24.58"
  entry <- readText (join root (testDir ++ "/Spec.hs"))
  require ("hspec-discover" `isInfixOf` entry) "test/Spec.hs must use hspec-discover"
  require (length cabals == 1) "The Stack profile requires one package per target root"
  cabal <- readText (join root (concat (take 1 cabals)))
  let components = cabalSections True cabal
      suites = cabalSections False cabal
  require
    (any (\s -> sourceDir `isInfixOf` s && all (dependsOn s) ["text", "bytestring"]) components)
    "The component compiling generated source must directly depend on text and bytestring"
  require
    (any (\s -> all (dependsOn s) ["hspec", "hedgehog", "hspec-hedgehog"] && testDir `isInfixOf` s && "Spec.hs" `isInfixOf` s) suites)
    "A test suite must directly depend on Hspec/Hedgehog and discover the configured test directory"
  pure (("ghc", JString ghc) : filter ((/= "ghc") . fst) (drop 1 versions) `seq` versions)

-- | The library and test-suite stanzas of a .cabal file, each up to the
-- next line that starts in the first column (doctor.mjs's two splits).
cabalSections :: Bool -> String -> [String]
cabalSections withLibraries cabal = [stanza body | (header, body) <- headed (lines cabal), opens header]
  where
    opens header
      | withLibraries = header == "library" || ("library" `isPrefixOf` header && startsSpaced (drop 7 header)) || ("test-suite" `isPrefixOf` header && startsSpaced (drop 10 header))
      | otherwise = "test-suite" `isPrefixOf` header && startsSpaced (drop 10 header)
    startsSpaced rest = take 1 rest `elem` [" ", "\t"]
    headed allLines = [(trimEnd line, rest) | (line : rest) <- tails allLines]
    trimEnd = reverse . dropWhile (`elem` (" \t" :: String)) . reverse
    stanza rest = unlines (takeWhile (\line -> all isSpace (take 1 line)) rest)

-- | (?:^|[\s,])name(?=[\s,<>=]|$) in one stanza.
dependsOn :: String -> String -> Bool
dependsOn stanza name = any matches (tails ('\n' : stanza))
  where
    matches (before : rest) =
      (isSpace before || before == ',')
        && name `isPrefixOf` rest
        && case drop (length name) rest of
          [] -> True
          c : _ -> isSpace c || c `elem` (",<>=" :: String)
    matches [] = False

-- | The contents of every <plugin> element of an effective POM.
plugins :: String -> [String]
plugins pom = case breakOn "<plugin>" pom of
  Nothing -> []
  Just rest -> case breakOn "</plugin>" rest of
    Nothing -> []
    Just after -> take (length rest - length after - length ("</plugin>" :: String)) rest : plugins after

-- | The text after the first occurrence of a needle.
breakOn :: String -> String -> Maybe String
breakOn needle haystack = listToMaybe [drop (length needle) rest | rest <- tails haystack, needle `isPrefixOf` rest]

lastPlugin :: String -> [String] -> String
lastPlugin artifact found = case filter (("<artifactId>" ++ artifact ++ "</artifactId>") `isInfixOf`) found of
  [] -> ""
  matching -> last matching

-- | The text of every element with one of the given names: <name>text</.
elementTexts :: [String] -> String -> [String]
elementTexts names text = [takeWhile (/= '<') rest | name <- names, rest <- occurrences ("<" ++ name ++ ">") text, "</" `isPrefixOf` dropWhile (/= '<') rest]
  where
    occurrences needle haystack = [drop (length needle) t | t <- tails haystack, needle `isPrefixOf` t]

java :: (Monad m) => Json -> FilePath -> [Json] -> String -> String -> Probe m [(String, Json)]
java target root planned sourceDir testDir = do
  let command = fromMaybe "mvn" (field "maven" target)
  versionText <- run root [] command ["-version"]
  let javaVersion = case breakOn "Java version:" versionText of
        Just rest -> let digits = takeWhile (\c -> isDigit c || c == '.') (dropWhile isSpace rest) in if null digits then Nothing else Just digits
        Nothing -> Nothing
      release = maybe (toInteger defaultJavaRelease) (\value -> case value of JNumber n -> round n; _ -> -1) (member "release" target)
      releases = map toInteger javaReleases
  require (release `elem` releases) ("release " ++ maybe "undefined" jsString (member "release" target) ++ " is not supported for java; choose " ++ intercalate " or " (map show releases))
  require (atLeast javaVersion release) ("Maven must run on Java " ++ show release ++ "+")
  pom <- run root [] command ["help:effective-pom"]
  let found = plugins pom
      compiler = lastPlugin "maven-compiler-plugin" found
  require (any (\v -> "3.14." `isPrefixOf` v || "3.15." `isPrefixOf` v) (elementTexts ["version"] compiler)) "Maven compiler plugin 3.14.x or 3.15.x is required"
  require (not (any (\tag -> ("<" ++ tag ++ ">") `isInfixOf` pom) ["jdkToolchain", "executable", "jvm"])) "Custom JVM/toolchain overrides cannot be verified by the v0.1 Maven profile"
  let releaseAdvice =
        if release == toInteger defaultJavaRelease
          then "set :release " ++ intercalate " or " [show r | r <- releases, r /= release] ++ " on the target in lawspec.edn if the build compiles at another supported release"
          else "it is the target's :release in lawspec.edn"
  require
    (all (== show release) (elementTexts ["release", "testRelease"] compiler))
    ("All effective compiler releases must be " ++ show release ++ "; " ++ releaseAdvice)
  require
    (show release `elem` elementTexts ["maven.compiler.release", "release"] pom)
    ("The effective Maven compiler release must be " ++ show release ++ "; " ++ releaseAdvice)
  require
    (("<sourceDirectory>" ++ join root sourceDir ++ "</sourceDirectory>") `isInfixOf` pom && ("<testSourceDirectory>" ++ join root testDir ++ "</testSourceDirectory>") `isInfixOf` pom)
    "Maven source directories must match the configured LawSpec layout"
  let helper = lastPlugin "build-helper-maven-plugin" found
      registers goal element directory =
        ("<goal>" ++ goal ++ "</goal>") `isInfixOf` helper
          && any (\d -> ("<" ++ element ++ ">" ++ d ++ "</" ++ element ++ ">") `isInfixOf` helper) [directory, join root directory]
      generatedSource = field "generatedSourceDir" target
      generatedTest = field "generatedTestDir" target
      resources = case generatedTest of
        Just directory -> any (\artifact -> let p = maybe "" jsString (member "path" artifact) in (directory ++ "/") `isPrefixOf` p && not (".java" `isSuffixOf` p)) planned
        Nothing -> False
      -- The LawSpec Maven plugin's generate goal adds the directories
      -- itself, unless its addSourceRoots is off.
      lawspecPlugin = lastPlugin "lawspec-maven-plugin" found
      pluginRegisters =
        "<goal>generate</goal>" `isInfixOf` lawspecPlugin
          && not ("<addSourceRoots>false</addSourceRoots>" `isInfixOf` lawspecPlugin)
  require
    ( pluginRegisters
        || ( maybe True (registers "add-source" "source") generatedSource
               && maybe True (\d -> registers "add-test-source" "source" d && (not resources || registers "add-test-resource" "directory" d)) generatedTest
           )
    )
    ("Maven must compile the target's generated directories. Bind the LawSpec Maven plugin's generate goal, which adds them, or add:\n" ++ generatedRootsAdvice generatedSource generatedTest)
  tree <- run root [] command ["dependency:tree", "-Dscope=test", "-DoutputType=text"]
  let resolved artifact = listToMaybe [version | rest <- tails tree, (artifact ++ ":jar:") `isPrefixOf` rest, let after = drop (length artifact + 5) rest, let version = takeWhile (\c -> c /= ':' && not (isSpace c)) after, not (null version), scoped (drop (length version) after)]
      scoped after = case after of
        ':' : rest -> not (null (takeWhile isWord rest))
        _ -> False
      isWord c = isDigit c || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c == '_'
      jetCheck = resolved "org.jetbrains:jetCheck"
      api = resolved "org.junit.jupiter:junit-jupiter-api"
      engine = resolved "org.junit.jupiter:junit-jupiter-engine"
      junitBom = "Dependency management decides this version, whatever the dependency declares: a BOM such as Spring Boot's manages JUnit. Import org.junit:junit-bom 5.14.0 in dependencyManagement before that BOM."
  require (isJust jetCheck) "JetCheck (org.jetbrains:jetCheck) must be a test dependency"
  require (isJust api) "JUnit Jupiter (org.junit.jupiter:junit-jupiter) must be a test dependency"
  require (supported "java" "junit-jupiter" api) ("The build resolves junit-jupiter-api " ++ fromMaybe "" api ++ ", outside the verified java profile [5.14.0, 6.1.0). " ++ junitBom)
  require (surefire35 pom) "Surefire 3.5.x is required"
  require (not ("<skipTests>true</skipTests>" `isInfixOf` pom || "<maven.test.skip>true</maven.test.skip>" `isInfixOf` pom)) "Maven test execution is disabled"
  let surefire = lastPlugin "maven-surefire-plugin" found
  require
    (not (any (\tag -> ("<" ++ tag ++ ">") `isInfixOf` surefire) ["includes", "excludes", "groups", "excludedGroups"] || any (\tag -> ("<" ++ tag ++ ">true<") `isInfixOf` surefire) ["skip", "testFailureIgnore"]))
    "Custom Surefire filtering or ignored failures cannot be verified"
  require (isJust engine) "The JUnit Jupiter test engine must be on the test classpath"
  require (engine == api) ("The build resolves junit-jupiter-engine " ++ fromMaybe "" engine ++ " beside junit-jupiter-api " ++ fromMaybe "" api ++ "; they must be one release. " ++ junitBom)
  pure [("java", maybe JNull JString javaVersion), ("jetCheck", maybe JNull JString jetCheck), ("junit-jupiter", maybe JNull JString api)]
  where
    -- <artifactId>maven-surefire-plugin</artifactId>\s*<version>3\.5\.
    surefire35 pom = any (\rest -> "<version>3.5." `isPrefixOf` dropWhile isSpace rest) [drop (length marker) t | t <- tails pom, marker `isPrefixOf` t]
    marker = "<artifactId>maven-surefire-plugin</artifactId>"

rust :: (Monad m) => Json -> FilePath -> [Json] -> String -> String -> Probe m [(String, Json)]
rust target root planned sourceDir testDir = do
  let compiler = fromMaybe "rustc" (field "rustc" target)
      cargo = fromMaybe "cargo" (field "cargo" target)
  reported <- run root [] compiler ["--version"]
  let version = if "rustc " `isPrefixOf` reported then versionAfter "rustc " 2 2 (take 40 reported) >>= \v -> if ("rustc " ++ v) `isPrefixOf` reported then Just v else Nothing else Nothing
  require (maybe False (\v -> compareVersions v "1.85.0" >= 0) version) "Rust 1.85+ is required"
  metadata <- run root [] cargo ["metadata", "--format-version", "1"] >>= parse
  let packages = fromMaybe [] (member "packages" metadata >>= arrayOf)
      manifestPath = join root "Cargo.toml"
      package = find (\p -> fmap (resolve root) (member "manifest_path" p >>= stringOf) == Just manifestPath) packages
  pkg <- maybe (throwE "Select a Cargo package directory containing Cargo.toml") pure package
  require (member "edition" pkg == Just (JString "2024")) "Cargo package must use edition 2024"
  let nodes = fromMaybe [] (member "resolve" metadata >>= member "nodes" >>= arrayOf)
      node = find (\n -> member "id" n == member "id" pkg) nodes
  dependencies <- forM ["proptest", "num-bigint", "num-rational", "num-complex", "num-traits"] $ \dependency -> do
    let reference = node >>= \n -> find (\d -> member "name" d == Just (JString (map (\c -> if c == '-' then '_' else c) dependency))) (fromMaybe [] (member "deps" n >>= arrayOf))
        version' = reference >>= \r -> find (\p -> member "id" p == member "pkg" r) packages >>= member "version"
    require (maybe False isTruthy version') ("Missing direct Cargo dependency: " ++ dependency)
    pure (dependency, fromMaybe JNull version')
  manifest <- readText manifestPath
  require (not (assignment "harness" "false" manifest)) "Rust generated tests require the standard Cargo test harness"
  let testRoot = resolve root testDir
  expected <-
    if not (null planned)
      then pure [resolve root p | artifact <- planned, member "placement" artifact == Just (JString "test"), Just p <- [member "path" artifact >>= stringOf], "_lawspec.rs" `isSuffixOf` p]
      else (\names -> [join testRoot n | n <- fromMaybe [] names, "_lawspec.rs" `isSuffixOf` n]) <$> listNames testRoot
  let targets = fromMaybe [] (member "targets" pkg >>= arrayOf)
      kinds t = [k | Just (JArray ks) <- [member "kind" t], JString k <- ks]
  when (testDir /= "tests" || assignment "autotests" "false" manifest) $ do
    let registered = [resolve root s | t <- targets, "test" `elem` kinds t, maybe False isTruthy (member "test" t), Just s <- [member "src_path" t >>= stringOf]]
    require
      (if not (null expected) then all (`elem` registered) expected else any ((testRoot ++ "/") `isPrefixOf`) registered)
      "Register every generated Rust test file with Cargo [[test]] entries for this custom layout"
  let library = find (\t -> "lib" `elem` kinds t) targets
  require
    (maybe True (\l -> fmap (takeDirectory . resolve root) (member "src_path" l >>= stringOf) == Just (resolve root sourceDir)) library)
    "Cargo library path must match the configured sourceDir"
  pure (("rust", maybe JNull JString version) : dependencies)
  where
    -- name\s*=\s*value
    assignment name value text = any (\rest -> case dropWhile isSpace (drop (length name) rest) of '=' : more -> value `isPrefixOf` dropWhile isSpace more; _ -> False) [t | t <- tails text, name `isPrefixOf` t]

-- | The Gradle command (prepare.mjs gradleFor).
gradleCommand :: (Monad m) => Json -> FilePath -> Probe m String
gradleCommand target root = case member "gradle" target of
  Just value | isTruthy value -> pure (jsString value)
  _ -> do
    present <- exists (join root "gradlew")
    pure (if present then join root "gradlew" else "gradle")

gradleReport :: (Monad m) => Json -> FilePath -> String -> Probe m Json
gradleReport target root script = do
  command <- gradleCommand target root
  scratch <- lift (temporaryDirectory "lawspec-gradle-")
  let report = join scratch "report.json"
      initScript = join scratch "inspect.gradle"
  result <- lift . runExceptT $ do
    _ <- lift (effectOr (WriteFile Replace Nothing initScript (utf8 script)))
    _ <- run root [("LAWSPEC_REPORT", Just report)] command ["--no-daemon", "--console=plain", "-I", initScript, "lawspecEnvironmentReport"]
    readText report >>= parse
  lift (removeTree scratch)
  either throwE pure result

kotlinScript :: String
kotlinScript = "import groovy.json.JsonOutput\ngradle.projectsEvaluated {\n def p = gradle.rootProject\n p.tasks.register('lawspecEnvironmentReport') { doLast {\n def k = p.tasks.findByName('compileTestKotlin')\n def j = p.tasks.findByName('test')\n def plugin = p.plugins.findPlugin('org.jetbrains.kotlin.jvm')\n def kv = plugin.class.classLoader.loadClass('org.jetbrains.kotlin.gradle.plugin.KotlinPluginWrapperKt').getMethod('getKotlinPluginVersion', org.gradle.api.Project).invoke(null, p)\n def deps = p.configurations.testRuntimeClasspath.resolvedConfiguration.resolvedArtifacts.collect { [name: it.moduleVersion.id.group + ':' + it.name, version: it.moduleVersion.id.version] }\n def mainDeps = p.configurations.runtimeClasspath.resolvedConfiguration.resolvedArtifacts.collect { it.moduleVersion.id.group + ':' + it.name }\n new File(System.getenv('LAWSPEC_REPORT')).text = JsonOutput.toJson([kotlin: kv, gradle: gradle.gradleVersion, java: System.getProperty('java.version'), target: k?.compilerOptions?.jvmTarget?.get()?.target, testJava: j?.javaLauncher?.get()?.metadata?.languageVersion?.asInt(), runner: j?.options?.class?.name, enabled: j.enabled, includes: j.filter.includePatterns, excludes: j.filter.excludePatterns, sourceDirs: p.sourceSets.main.allSource.srcDirs.collect { it.canonicalPath }, testDirs: p.sourceSets.test.allSource.srcDirs.collect { it.canonicalPath }, dependencies: deps, mainDependencies: mainDeps])\n } }\n}\n"

groovyScript :: String
groovyScript = "import groovy.json.JsonOutput\ngradle.projectsEvaluated {\n def p = gradle.rootProject\n p.tasks.register('lawspecEnvironmentReport') { doLast {\n def j = p.tasks.findByName('test')\n def deps = p.configurations.testRuntimeClasspath.resolvedConfiguration.resolvedArtifacts.collect { [name: it.moduleVersion.id.group + ':' + it.name, version: it.moduleVersion.id.version] }\n new File(System.getenv('LAWSPEC_REPORT')).text = JsonOutput.toJson([gradle: gradle.gradleVersion, java: System.getProperty('java.version'), testJava: j?.javaLauncher?.get()?.metadata?.languageVersion?.asInt(), runner: j?.options?.class?.name, enabled: j.enabled, includes: j.filter.includePatterns, excludes: j.filter.excludePatterns, sourceDirs: p.sourceSets.main.groovy.srcDirs.collect { it.canonicalPath }, testDirs: p.sourceSets.test.groovy.srcDirs.collect { it.canonicalPath }, dependencies: deps])\n } }\n}\n"

texts :: String -> Json -> [String]
texts key value = [text | Just (JArray items) <- [member key value], JString text <- items]

gradleMajor :: Json -> Bool
gradleMajor data' = case member "gradle" data' >>= stringOf of
  Just version -> any (`isPrefixOf` version) ["9.1.", "9.2.", "9.3."]
  Nothing -> False

numberAtLeast :: Maybe Json -> Integer -> Bool
numberAtLeast value minimum' = case value of
  Just (JNumber n) -> n >= fromInteger minimum'
  Just (JString text) -> maybe False (>= minimum') (if all isDigit text && not (null text) then Just (read text) else Nothing)
  _ -> False

unfilteredJUnit :: Json -> Bool
unfilteredJUnit data' =
  maybe False ("JUnitPlatform" `isInfixOf`) (member "runner" data' >>= stringOf)
    && maybe False isTruthy (member "enabled" data')
    && null (texts "includes" data')
    && null (texts "excludes" data')
    && maybe True (\v -> v == JArray []) (member "includes" data')
    && maybe True (\v -> v == JArray []) (member "excludes" data')

kotlin :: (Monad m) => Json -> FilePath -> String -> String -> Probe m [(String, Json)]
kotlin target root sourceDir testDir = do
  data' <- gradleReport target root kotlinScript
  require
    (gradleMajor data' && atLeast (member "java" data' >>= stringOf) 25 && numberAtLeast (member "target" data') 25 && numberAtLeast (member "testJava" data') 25)
    "Kotlin requires Gradle 9.1–9.3 and Java/JVM target/test runtime 25+"
  require (unfilteredJUnit data') "Gradle test must enable unfiltered JUnit Platform execution"
  require
    (join root sourceDir `elem` texts "sourceDirs" data' && join root testDir `elem` texts "testDirs" data')
    "Gradle source sets must include the configured LawSpec directories"
  let dependencies = fromMaybe [] (member "dependencies" data' >>= arrayOf)
  forM_ ["io.kotest:kotest-property-jvm", "io.kotest:kotest-runner-junit5-jvm", "io.kotest:kotest-assertions-core-jvm"] $ \dependency ->
    require
      (any (\d -> member "name" d == Just (JString dependency) && member "version" d == Just (JString "5.9.1")) dependencies)
      ("Missing " ++ dependency ++ ":5.9.1")
  require
    ("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm" `elem` texts "mainDependencies" data')
    "Missing org.jetbrains.kotlinx:kotlinx-coroutines-core (an implementation dependency, for workflows)"
  let versions = members data'
  require (maybe False isTruthy (member "kotlin" data')) "Cannot determine the Kotlin Gradle plugin version"
  pure versions

groovy :: (Monad m) => Json -> FilePath -> String -> String -> Probe m [(String, Json)]
groovy target root sourceDir testDir = do
  data' <- gradleReport target root groovyScript
  require
    (gradleMajor data' && atLeast (member "java" data' >>= stringOf) 25 && numberAtLeast (member "testJava" data') 25)
    "Groovy requires Gradle 9.1–9.3 and a Java 25+ toolchain"
  require (unfilteredJUnit data') "Gradle test must enable unfiltered JUnit Platform execution"
  let sources = if isJust (field "sourceDir" target) then [sourceDir] else [sourceDir, "src/main/java"]
      tests = if isJust (field "testDir" target) then [testDir] else [testDir, "src/test/java"]
  require
    (all (\d -> join root d `elem` texts "sourceDirs" data') sources && all (\d -> join root d `elem` texts "testDirs" data') tests)
    ("Gradle's Groovy source sets must include " ++ intercalate " and " sources ++ ", and " ++ intercalate " and " tests)
  let dependencies = fromMaybe [] (member "dependencies" data' >>= arrayOf)
      versionOf dependency = find (\d -> member "name" d == Just (JString dependency)) dependencies >>= member "version" >>= stringOf
      groovyVersion = versionOf "org.apache.groovy:groovy"
      spock = fmap (\v -> maybe v (\i -> take i v) (findIndex' "-groovy-" v)) (versionOf "org.spockframework:spock-core")
  require (isJust groovyVersion) "Missing org.apache.groovy:groovy"
  require (isJust spock) "Missing org.spockframework:spock-core"
  require (versionOf "org.jetbrains:jetCheck" == Just "0.3.0") "Missing org.jetbrains:jetCheck:0.3.0"
  pure [("groovy", JString (fromMaybe "" groovyVersion)), ("spock", JString (fromMaybe "" spock)), ("gradle", fromMaybe JNull (member "gradle" data')), ("java", fromMaybe JNull (member "java" data'))]
  where
    findIndex' needle text = listToMaybe [i | (i, rest) <- zip [0 ..] (tails text), needle `isPrefixOf` rest]

scala :: (Monad m) => Json -> FilePath -> String -> String -> Probe m [(String, Json)]
scala target root sourceDir testDir = do
  let command = fromMaybe "scala" (field "scala" target)
  reported <- run root [] command ["version"]
  let cli = case after "Scala code runner version:" reported of
        Just v -> Just v
        Nothing -> after "Scala CLI version:" reported
  javaText <- lift (either id id <$> runExceptT (run root [] "java" ["--version"]))
  let javaVersion = listToMaybe [takeWhile (not . isSpace) (dropWhile isSpace rest) | line <- lines javaText, Just rest <- [stripAny ["openjdk", "java"] line], any isSpace (take 1 rest), not (null (dropWhile isSpace rest))]
  require (atLeast (Just (fromMaybe "0" javaVersion)) 25) "Scala requires JDK 25+"
  project <- fromMaybe "" <$> readMaybe' (join root "project.scala")
  let directive keyword = listToMaybe [v | line <- lines project, Just v <- [usingDirective keyword line]]
      scalaVersion = directive "scala"
      scalacheck = directive "org.scalacheck::scalacheck:"
      scalatest = directive "org.scalatest::scalatest-funsuite:"
  require (isJust scalaVersion) "project.scala must name Scala 3 (//> using scala 3.9.0)"
  require (isJust scalacheck) "project.scala must add ScalaCheck (//> using test.dep org.scalacheck::scalacheck:1.20.0)"
  require (isJust scalatest) "project.scala must add ScalaTest (//> using test.dep org.scalatest::scalatest-funsuite:3.2.20)"
  require ("main" `elem` splitOn '/' sourceDir || "test" `notElem` splitOn '/' sourceDir) "The Scala source directory must not be under a directory named test, which Scala CLI compiles as tests"
  require ("test" `elem` splitOn '/' testDir) "The Scala test directory must be under a directory named test, which Scala CLI compiles as tests"
  pure [("scala-cli", maybe JNull JString cli), ("java", maybe JNull JString javaVersion), ("scala", maybe JNull JString scalaVersion), ("scalacheck", maybe JNull JString scalacheck), ("scalatest", maybe JNull JString scalatest)]
  where
    after label text = listToMaybe [word | rest <- tails text, label `isPrefixOf` rest, let word = takeWhile (not . isSpace) (dropWhile isSpace (drop (length label) rest)), not (null word)]
    stripAny prefixes line = listToMaybe [drop (length p) line | p <- prefixes, p `isPrefixOf` line]
    -- //>\s*using\s+scala\s+"?([0-9][^\s"]*) and the test.dep(s) forms.
    usingDirective keyword line = do
      rest <- breakOn "//>" line
      afterUsing <- spaced "using" (dropWhile isSpace rest)
      if keyword == "scala"
        then do
          value <- spaced "scala" afterUsing
          let unquoted = case value of '"' : more -> more; other -> other
          case unquoted of
            c : _ | isDigit c -> Just (takeWhile (\x -> not (isSpace x) && x /= '"') unquoted)
            _ -> Nothing
        else do
          value <- spaced "test.deps" afterUsing `orElse'` spaced "test.dep" afterUsing
          let unquoted = case value of '"' : more -> more; other -> other
          coordinate <- if keyword `isPrefixOf` unquoted then Just (drop (length keyword) unquoted) else Nothing
          let version = takeWhile (\x -> not (isSpace x) && x /= '"') coordinate
          if null version then Nothing else Just version
    spaced word text = if word `isPrefixOf` text && take 1 (drop (length word) text) `elem` [" ", "\t"] then Just (dropWhile isSpace (drop (length word) text)) else Nothing
    orElse' (Just x) _ = Just x
    orElse' Nothing y = y

clojure :: (Monad m) => Json -> FilePath -> Probe m [(String, Json)]
clojure target root = do
  deps <- readText (join root "deps.edn")
  require
    ("\"target/classes\"" `isInfixOf` deps && "\"target/test-classes\"" `isInfixOf` deps)
    "deps.edn must put target/classes on :paths and target/test-classes on the :test alias's :extra-paths"
  require ("lawspec.test-runner" `isInfixOf` deps) "deps.edn's :test alias must run lawspec.test-runner (:main-opts [\"-m\" \"lawspec.test-runner\"])"
  let command = fromMaybe "clojure" (field "clojure" target)
  classpath <- run root [] command ["-Spath", "-M:test"]
  let jarVersion prefix = listToMaybe [v | rest <- tails classpath, prefix `isPrefixOf` rest, Just v <- [versionAfter prefix 2 2 rest >>= \v -> if (prefix ++ v ++ ".jar") `isPrefixOf` rest then Just v else Nothing]]
      clojureVersion = jarVersion "clojure-"
      testCheck = jarVersion "test.check-"
  require (isJust clojureVersion) "Missing org.clojure/clojure in deps.edn"
  require (isJust testCheck) "Missing org.clojure/test.check in deps.edn's :test alias"
  javaText <- run root [] "java" ["--version"]
  let javaVersion = firstNumber javaText
  require (atLeast javaVersion 25) "Clojure needs a JDK 25+ (its compiler builds the Java model)"
  pure [("clojure", maybe JNull JString clojureVersion), ("test.check", maybe JNull JString testCheck), ("java", maybe JNull JString javaVersion)]
  where
    -- \b(\d+)(\.\d+)*: the first number not inside a word.
    firstNumber text = listToMaybe [number rest | (before, rest) <- zip (' ' : text) (tails text), not (isWordChar before), any isDigit (take 1 rest)]
    isWordChar c = isDigit c || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c == '_'
    number rest = let (digits, more) = span isDigit rest in digits ++ fraction more
    fraction ('.' : more) | (d@(_ : _), rest) <- span isDigit more = '.' : d ++ fraction rest
    fraction _ = ""

dotnet :: (Monad m) => String -> Json -> FilePath -> String -> String -> Probe m [(String, Json)]
dotnet name target root sourceDir testDir = do
  let extension = if name == "fsharp" then ".fsproj" else ".csproj"
  version <- trim <$> run root [] (fromMaybe "dotnet" (field "dotnet" target)) ["--version"]
  require (atLeast (Just version) 10) ".NET SDK 10+ is required"
  globalText <- fromMaybe "{}" <$> readMaybe' (join root "global.json")
  global <- parse globalText
  require
    ((member "test" global >>= member "runner") == Just (JString "Microsoft.Testing.Platform"))
    "global.json must select the Microsoft.Testing.Platform test runner: { \"test\": { \"runner\": \"Microsoft.Testing.Platform\" } }"
  let projects folder = filter (extension `isSuffixOf`) . fromMaybe [] <$> listNames (join root folder)
  sources <- projects sourceDir
  tests <- projects testDir
  require (length sources == 1) ("Expected one " ++ extension ++ " project in " ++ sourceDir)
  require (length tests == 1) ("Expected one " ++ extension ++ " project in " ++ testDir)
  let sourceProject = concat (take 1 sources)
      testProject = concat (take 1 tests)
  source <- readText (join root (sourceDir ++ "/" ++ sourceProject))
  test <- readText (join root (testDir ++ "/" ++ testProject))
  require ("LawSpec.Sources.props" `isInfixOf` source) (sourceDir ++ "/" ++ sourceProject ++ " must import LawSpec.Sources.props")
  require ("LawSpec.Tests.props" `isInfixOf` test) (testDir ++ "/" ++ testProject ++ " must import LawSpec.Tests.props")
  let xunit = listToMaybe [takeWhile (/= '"') rest | t <- tails test, Just rest <- [packageReference t]]
  require (isJust xunit) (testDir ++ "/" ++ testProject ++ " must reference the xunit.v3 package")
  pure [("dotnet", JString version), ("xunit.v3", maybe JNull JString xunit)]
  where
    -- <PackageReference\s+Include="xunit\.v3"\s+Version="([^"]+)"
    packageReference text = do
      rest <- if "<PackageReference" `isPrefixOf` text then Just (drop 17 text) else Nothing
      afterInclude <- spacedThen "Include=\"xunit.v3\"" rest
      afterVersion <- spacedThen "Version=\"" afterInclude
      if take 1 afterVersion /= "\"" && not (null afterVersion) then Just afterVersion else Nothing
    spacedThen token text = case text of
      c : _ | isSpace c, token `isPrefixOf` dropWhile isSpace text -> Just (drop (length token) (dropWhile isSpace text))
      _ -> Nothing

swift :: (Monad m) => Json -> FilePath -> Probe m [(String, Json)]
swift target root = do
  reported <- run root [] (fromMaybe "swift" (field "swift" target)) ["--version"]
  let version = versionAfter "Swift version " 1 2 reported
  require (isJust version) "Cannot determine the Swift version (swift --version)"
  manifest <- fromMaybe "" <$> readMaybe' (join root "Package.swift")
  require (not (null manifest)) "Missing Package.swift"
  forM_ ["LawSpecRuntime", "LawSpecTesting"] $ \module' ->
    require (("\"lawspec/" ++ module' ++ "\"") `isInfixOf` manifest) ("Package.swift must declare the target " ++ module' ++ " at lawspec/" ++ module' ++ ", as lawspec init does")
  pure [("swift", maybe JNull JString version)]

-- | The runtime files the BEAM doctor stages, by their RuntimeSources key
-- and their file under runtime/ (beam-doctor.mjs's embedded runtime).
beamDoctorRuntime :: [(String, FilePath)]
beamDoctorRuntime =
  [ ("beam-exunit-formatter", "lawspec_beam_exunit_formatter.ex"),
    ("beam-crypto_native", "lawspec_beam_crypto_native.erl"),
    ("beam-crypto-native-c", "lawspec_crypto_native.c"),
    ("beam-crypto-build", "lawspec_crypto_build.escript")
  ]

-- | beam-doctor.mjs satisfiesRequirement(): a Hex requirement of stable
-- numeric versions (or, and, ~>, comparisons).
satisfiesRequirement :: String -> String -> Either String Bool
satisfiesRequirement version requirement = do
  unless (dotted version) (Left ("Cannot verify dependency version " ++ version))
  clauses <- forM (splitWords "or" (trim requirement)) $ \clause ->
    forM (splitWords "and" clause) $ \term -> do
      let (operator, wanted) = operatorOf (trim term)
      unless (dotted wanted) (Left ("Cannot verify Hex requirement " ++ stringify (JString requirement) ++ "; use an exact stable version"))
      let difference = compareVersions version wanted
      case operator of
        "~>" -> do
          let parts = map read (splitOn '.' wanted) :: [Integer]
          unless (length parts `elem` [2, 3]) (Left ("Cannot verify Hex requirement " ++ stringify (JString requirement)))
          let upper = case parts of
                [a, _] -> show (a + 1) ++ ".0.0"
                a : b : _ -> show a ++ "." ++ show (b + 1) ++ ".0"
                _ -> wanted
          pure (difference >= 0 && compareVersions version upper < 0)
        "==" -> pure (difference == 0)
        "!=" -> pure (difference /= 0)
        ">=" -> pure (difference >= 0)
        "<=" -> pure (difference <= 0)
        ">" -> pure (difference > 0)
        _ -> pure (difference < 0)
  pure (any and clauses)
  where
    dotted text = not (null text) && all (\part -> not (null part) && all isDigit part) (splitOn '.' text)
    operatorOf term = case [(op, trim (drop (length op) term)) | op <- ["~>", ">=", "<=", "==", "!=", ">", "<"], op `isPrefixOf` term] of
      found : _ -> found
      [] -> ("==", term)
    splitWords word text = go [] (words' text)
      where
        go kept [] = [unwords (reverse kept)]
        go kept (w : ws) | w == word = unwords (reverse kept) : go [] ws | otherwise = go (w : kept) ws
        words' = words

beam :: (Monad m) => String -> Json -> FilePath -> [Json] -> Probe m ([(String, Json)], Maybe Json)
beam name target root planned = do
  let sourceDir = fromMaybe (if name == "elixir" then "lib" else "src") (field "sourceDir" target)
      testDir = fromMaybe "test" (field "testDir" target)
  needsCrypto <-
    if not (null planned)
      then pure (any (\a -> member "path" a == Just (JString "priv/lawspec_crypto_native.c")) planned)
      else exists (join root "priv/lawspec_crypto_native.c")
  scratch <- lift (temporaryDirectory "lawspec-beam-doctor-")
  result <- lift (runExceptT (beamProbe name root scratch (field "sourceDir" target) sourceDir testDir needsCrypto))
  lift (removeTree scratch)
  either throwE pure result

beamProbe :: (Monad m) => String -> FilePath -> FilePath -> Maybe String -> String -> String -> Bool -> Probe m ([(String, Json)], Maybe Json)
beamProbe name root scratch configuredSource sourceDir testDir needsCrypto = do
  let probeFile = join scratch "probe.escript"
      input = join scratch "input.json"
      output = join scratch "output.json"
      writeText file contents = () <$ lift (effectOr (WriteFile Replace Nothing file (utf8 contents)))
      includesPath directories directory = any (\item -> resolve root item == resolve root directory) directories
      inspect mode options = do
        writeText input (compact (JObject (("mode", JString mode) : options)))
        _ <- lift (effectOr (Remove NotRecursive output))
        _ <- run root [] "escript" [probeFile, input, output]
        readText output >>= parse
  writeText probeFile erlangProbe
  otp <- trim <$> run root [] "erl" ["-noshell", "-eval", "io:put_chars(erlang:system_info(otp_release)), halt()."]
  require (otp == "29") ("BEAM targets require the verified Erlang/OTP 29 profile; found " ++ otp)
  versions0 <- members <$> inspect "otp" []
  (versions1, coverage) <- case name of
    "erlang" -> do
      version <- run root [] "rebar3" ["version"]
      let rebar = listToMaybe [takeWhile (not . isSpace) rest | (before, t) <- zip (' ' : version) (tails version), not (isWordChar before), Just rest <- [stripPrefix' "rebar " t], not (null (takeWhile (not . isSpace) rest))]
      proper <- trim <$> run root [] "rebar3" ["as", "test", "path", "--app", "proper", "--ebin"]
      require (not (null proper) && '\n' `notElem` proper) "Cannot resolve PropEr; run rebar3 as test compile first"
      checkout <- exists (join root "_checkouts/proper")
      require (not checkout) "PropEr must resolve from Hex without a checkout replacement"
      data' <- inspect "rebar" [("archive", JString (join scratch "rebar.ez")), ("proper", JString proper)]
      require (truthy "proper_dependency" data') "PropEr must be a direct Hex dependency in the Rebar test profile"
      satisfied <- either throwE pure (satisfiesRequirement (text "proper" data') (text "proper_requirement" data'))
      require satisfied "PropEr's compiled version does not satisfy the test profile dependency; run rebar3 as test compile"
      require (includesPath (texts "src_dirs" data') sourceDir) "Rebar src_dirs must include the configured sourceDir"
      require (resolve root testDir == join root "test" || includesPath (texts "extra_src_dirs" data') testDir) "Rebar extra_src_dirs must include the configured testDir when it is not test"
      require (truthy "reporter" data') "Configure Rebar eunit_opts with {report, {lawspec_beam_report, []}} for native execution reports"
      require (not (truthy "filters" data') && not (truthy "alias" data')) "Rebar must use unfiltered EUnit discovery without eunit_tests or an eunit alias"
      require (not needsCrypto || truthy "crypto_hook" data') "Add the compile pre_hook: escript lawspec_crypto_build.escript"
      pure (assign versions0 [("rebar3", maybe JNull JString rebar), ("proper", fromMaybe JNull (member "proper" data'))], Nothing)
    "elixir" -> do
      let formatter = join scratch "formatter.ex"
          mixProbe = join scratch "probe.exs"
      writeText formatter (runtimeSource "beam-exunit-formatter")
      writeText mixProbe elixirProbe
      writeText input (compact (JObject [("formatter", JString formatter), ("test_dir", JString testDir)]))
      _ <- lift (effectOr (Remove NotRecursive output))
      offline <- lift (either (const Nothing) id <$> effectOr (GetEnvironment "LAWSPEC_OFFLINE"))
      _ <- run root ([("MIX_ENV", Just "test")] ++ [("HEX_OFFLINE", Just "1") | offline == Just "1"]) "mix" ["run", "--no-compile", "--no-start", "--no-deps-check", mixProbe, input, output]
      data' <- readText output >>= parse
      forM_ [("erlc_paths", fromMaybe "src" configuredSource), ("elixirc_paths", sourceDir), ("erlc_paths", testDir ++ "/support"), ("elixirc_paths", testDir ++ "/support"), ("test_paths", testDir)] $ \(key, directory) ->
        require (includesPath (texts key data') directory) ("Mix " ++ key ++ " must include " ++ directory ++ " in MIX_ENV=test")
      require ("erlang" `elem` texts "compilers" data' && "elixir" `elem` texts "compilers" data') "Mix must enable both erlang and elixir compilers"
      require (not (truthy "alias" data') && not (truthy "ignored" data') && member "test_pattern" data' == Just (JString "*_test.exs")) "Mix must discover *_test.exs without test_ignore_filters or aliases for test/compile.erlang/compile.elixir"
      require (truthy "reporter" data') "Configure LawSpec.Beam.ExUnitFormatter in test_helper.exs for native execution reports"
      require (not (truthy "filtered" data') && not (truthy "dry_run" data')) "ExUnit must run without include/exclude filters or dry_run"
      let maxFailures = member "max_failures" data'
      require
        (maxFailures == Just (JString "infinity") || maybe False positive (maxFailures >>= stringOf))
        "ExUnit max_failures must be a positive integer or :infinity"
      require (not needsCrypto || truthy "crypto_compiler" data') "Add :lawspec_crypto to Mix compilers and define Mix.Tasks.Compile.LawspecCrypto to run the bridge builder"
      pure (assign versions0 [("elixir", fromMaybe JNull (member "elixir" data')), ("stream_data", fromMaybe JNull (member "stream_data" data'))], member "coverage" data')
    _ -> do
      require (sourceDir == "src" && testDir == "test") "Gleam requires sourceDir=src and testDir=test; choose a separate project root for another layout"
      version <- run root [] "gleam" ["--version"]
      let gleamVersion = listToMaybe [takeWhile (not . isSpace) rest | (before, t) <- zip (' ' : version) (tails version), not (isWordChar before), Just rest <- [stripPrefix' "gleam " t], not (null (takeWhile (not . isSpace) rest))]
          configFile = join scratch "gleam.json"
      _ <- run root [] "gleam" ["export", "package-information", "--out", configFile]
      config <- maybe JNull id . member "gleam.toml" <$> (readText configFile >>= parse)
      require (member "target" config == Just (JString "erlang")) "gleam.toml must select target=erlang"
      let dependencyVersion section dependency = member section config >>= member dependency >>= member "version"
      require
        (maybe False isTruthy (dependencyVersion "dependencies" "gleam_stdlib") && all (\n -> maybe False isTruthy (dependencyVersion "dev_dependencies" n)) ["gleeunit", "qcheck"])
        "Gleam requires Hex gleam_stdlib plus direct gleeunit and qcheck dev-dependencies, without local replacements"
      require
        (resolve root (maybe "" jsString (member "dev_dependencies" config >>= member "lawspec_test_support" >>= member "path")) == join root "test-support")
        "Add lawspec_test_support = { path = \"./test-support\" } to Gleam dev-dependencies"
      _ <- run (join root "test-support") [] "gleam" ["export", "package-information", "--out", configFile]
      support <- maybe JNull id . member "gleam.toml" <$> (readText configFile >>= parse)
      require
        (member "name" support == Just (JString "lawspec_test_support") && member "target" support == Just (JString "erlang") && maybe False isTruthy (member "dependencies" support >>= member "qcheck" >>= member "version"))
        "test-support/gleam.toml must define lawspec_test_support for Erlang with a Hex qcheck dependency"
      let package = maybe "" jsString (member "name" config)
      runner <- trim . withoutLineComments <$> readText (join root ("test/" ++ package ++ "_test.gleam"))
      require
        (gleamRunner runner)
        ("Use @external(erlang, \"lawspec_beam_test_run\", \"gleam_main\") pub fn main() -> Nil in test/" ++ package ++ "_test.gleam; put tests in other *_test.gleam modules")
      listed <- run root [] "gleam" ["deps", "list"]
      let resolved = [(n, v) | line <- lines (trim listed), n : v : _ <- [words line]] ++ [(n, "") | line <- lines (trim listed), [n] <- [words line]]
      compiled <- inspect "gleam" [("root", JString root)]
      found <- forM ["gleam_stdlib", "gleeunit", "qcheck"] $ \dependency -> do
        let compiledVersion = maybe "" jsString (member dependency compiled)
        require (lookup dependency resolved == Just compiledVersion) (dependency ++ "'s compiled version differs from the resolved dependency; run gleam build")
        let requirement = maybe "undefined" jsString (dependencyVersion "dependencies" dependency `orElse` dependencyVersion "dev_dependencies" dependency)
        satisfied <- either throwE pure (satisfiesRequirement compiledVersion requirement)
        require satisfied (dependency ++ "'s compiled version does not satisfy gleam.toml; run gleam build")
        pure (dependency, JString compiledVersion)
      let qcheck = maybe "" jsString (lookup "qcheck" found)
      satisfied <- either throwE pure (satisfiesRequirement qcheck (maybe "undefined" jsString (member "dependencies" support >>= member "qcheck" >>= member "version")))
      require satisfied "qcheck's compiled version does not satisfy test-support/gleam.toml; run gleam build"
      pure (assign versions0 (("gleam", maybe JNull JString gleamVersion) : found), Nothing)
  versions2 <-
    if not needsCrypto
      then pure versions1
      else do
        let project = join scratch "lawspec_doctor_native"
            ebin = join project "ebin"
            builder = join project "lawspec_crypto_build.escript"
            native = join project "lawspec_beam_crypto_native.erl"
        _ <- lift (effectOr (MakeDirectories Nothing (join project "priv")))
        _ <- lift (effectOr (MakeDirectories Nothing ebin))
        writeText builder (runtimeSource "beam-crypto-build")
        writeText native (runtimeSource "beam-crypto_native")
        writeText (join project "priv/lawspec_crypto_native.c") (runtimeSource "beam-crypto-native-c")
        _ <- run root [] "escript" [builder, project]
        _ <- run root [] "erlc" ["-o", ebin, native]
        crypto <- inspect "crypto" [("ebin", JString ebin)]
        pure (assign versions1 (members crypto))
  pure (versions2, coverage)
  where
    truthy key value = maybe False isTruthy (member key value)
    text key value = maybe "" jsString (member key value)
    isWordChar c = isDigit c || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c == '_'
    stripPrefix' prefix t = if prefix `isPrefixOf` t then Just (drop (length prefix) t) else Nothing
    positive t = case t of
      c : cs -> c `elem` ['1' .. '9'] && all isDigit cs
      [] -> False
    orElse (Just x) _ = Just x
    orElse Nothing y = y
    withoutLineComments t = case t of
      '/' : '/' : rest -> withoutLineComments (dropWhile (/= '\n') rest)
      c : rest -> c : withoutLineComments rest
      [] -> []
    -- @external(erlang, "lawspec_beam_test_run", "gleam_main") pub fn main() -> Nil
    gleamRunner runner =
      let tokens = gleamTokens runner
       in tokens == ["@external", "(", "erlang", ",", "\"lawspec_beam_test_run\"", ",", "\"gleam_main\"", ")", "pub", "fn", "main", "(", ")", "->", "Nil"]
            && "@external(" `isPrefixOf` runner
            && hasSpaceBetween runner "pub" "fn"
            && hasSpaceBetween runner "fn" "main"
    gleamTokens t = case dropWhile isSpace t of
      [] -> []
      '"' : rest -> let (body, more) = break (== '"') rest in ('"' : body ++ "\"") : gleamTokens (drop 1 more)
      '-' : '>' : rest -> "->" : gleamTokens rest
      c : rest | c `elem` ("()," :: String) -> [c] : gleamTokens rest
      _ -> let (word, more) = span (\c -> not (isSpace c) && c `notElem` ("(),\"" :: String)) (dropWhile isSpace t) in word : gleamTokens more
    hasSpaceBetween t a b = any (\rest -> a `isPrefixOf` rest && let more = drop (length a) rest in any isSpace (take 1 more) && b `isPrefixOf` dropWhile isSpace more) (tails t)

-- | compiler-cache.mjs probeCache on a POSIX platform: can the compiler
-- write its deepest entry in the cache directory?
probeCache :: (Monad m) => CacheLocation -> String -> Command m Json
probeCache location build = do
  let directory = cacheFolder location
      entry = join directory (take 16 (build ++ replicate 16 '0') ++ "/zzz/" ++ replicate 32 'z')
      folder = takeDirectory entry
  grantWrite [directory]
  grantRead [directory]
  created <- firstMissing folder Nothing
  made <- effectOr (MakeDirectories Nothing folder)
  written <- case made of
    Left problem -> pure (Left (failureMessage (nodeFailure "mkdir" folder problem)))
    Right () ->
      effectOr (WriteFile Replace Nothing entry B.empty) >>= \case
        Left problem -> pure (Left (failureMessage (nodeFailure "open" entry problem)))
        Right () -> either (Left . failureMessage . nodeFailure "rm" entry) Right <$> effectOr (Remove NotRecursive entry)
  -- Only what this probe created goes (mkdir's first created directory),
  -- even above the cache directory: a project's .lawspec when the cache is
  -- its default. An existing build keeps its entries.
  forM_ created $ \first -> removeCreated Recursive first
  let base =
        [ ("target", JString "compiler cache"),
          ("kind", JString "cache"),
          ("directory", JString directory),
          ("source", JString (cacheSource location)),
          ("pathLength", integer (toInteger (length entry))),
          ("longPathsEnabled", JNull)
        ]
  pure . JObject $ case written of
    Right () -> base ++ [("ok", JBool True), ("detail", JString ("ready (" ++ directory ++ "; deepest entry " ++ show (length entry) ++ " characters)"))]
    Left message ->
      base
        ++ [ ("ok", JBool False),
             ("message", JString ("the compiler cache cannot be written: " ++ message ++ " (path of " ++ show (length entry) ++ " characters: " ++ entry ++ ")")),
             ("instructions", JString "Set LAWSPEC_COMPILER_CACHE, or :cache-directory in lawspec.edn, to a short writable directory. Until then every run compiles from nothing.")
           ]
  where
    -- The directory mkdir -p would create first: walking up from the
    -- folder, the last path that does not exist below the first that does.
    -- Only a definite NotFound counts as missing; any other answer (a
    -- refusal, an error) stops the walk with nothing to remove. Each stat
    -- is allowed for itself alone, so the walk widens no access.
    firstMissing path below
      | takeDirectory path == path = pure Nothing
      | otherwise = do
          status <- statAlone path
          case status of
            Right _ -> pure below
            Left problem | errorKind problem == NotFound -> firstMissing (takeDirectory path) (Just path)
            Left _ -> pure Nothing
    statAlone path = do
      before <- sessionPolicy <$> getSession
      grantRead [path]
      status <- effectOr (Stat NoFollow path)
      modifySession (\s -> s {sessionPolicy = before})
      pure status

-- | The doctor command: every selected target's report, then the cache's,
-- as text or JSON; exit 1 when any is not ok.
doctorCommand :: (Monad m) => Bool -> [(Json, FilePath)] -> Maybe CacheLocation -> String -> Command m Int
doctorCommand json selected location build = do
  reports <- forM selected $ \(target, root) -> doctor target root []
  cache <- maybe (pure []) (\l -> pure <$> probeCache l build) location
  let all' = reports ++ cache
      line report =
        maybe "undefined" jsString (member "target" report)
          ++ ": "
          ++ if member "ok" report == Just (JBool True)
            then maybe (if member "kind" report == Just (JString "artifact") then "generation ready" else "ready") jsString (member "detail" report)
            else maybe "undefined" jsString (member "message" report) ++ "\n" ++ maybe "undefined" jsString (member "instructions" report)
  if json then printJson (JArray all') else printLine (intercalate "\n" (map line all'))
  pure (if all (\r -> member "ok" r == Just (JBool True)) all' then 0 else 1)
