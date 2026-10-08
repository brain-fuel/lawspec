-- | Acceptance suites: generate a bundled example for a target in process,
-- install the suite's native adapters, run the target's own test tool, and
-- require every mutant to fail its laws at test time. ref:DEC-acceptance-with-mutants
--
--   lawspec-acceptance <suite> [target...]
--   lawspec-acceptance <suite> --check [target...]   generation only, compare disk
--   lawspec-acceptance <suite> --no-mutants [target...]  correct adapters only
--
-- A suite lives in acceptance/<suite>/:
--   suite.json                     {"specs": ["examples/specs/x.lawspec", ...],
--                                    "vectors": "test/scalar-vectors.json",  (optional)
--                                    "architecture": true,                  (optional)
--                                    "packages": ["examples/packages/p"],   (optional)
--                                    "dependencies": {"p.name": "^1.0.0"}}  (optional)
--   <target>/files/<path>          adapters replacing generated user-owned stubs
--   <target>/stubs/<path>          the stub an adapter was written against (optional)
--   <target>/mutants/<name>.mutant search/replace edits, one mutant per file
--                                  (a "rejected-at: compile" header line marks
--                                  one the target's compiler must reject)
--   <target>/bindings.json         native bindings, as in lawspec.json (optional)
--   <target>/native/<path>         application code those bindings call, copied
--                                  as is (bound units have no adapters)
--   recorded/<unit>/<name>         recorded values, copied to every target's
--                                  project as recorded/<unit>/<name> (optional)
--   mutants/<name>.mutant          spec mutants, for every target: edits to a
--                                  spec file, regenerated and run like any
--                                  mutant ("rejected-at: generation" marks one
--                                  the compiler must reject)
--
-- A package directory holds lawspec-package.json ({"name", "version",
-- "sources": [directories or files], "dependencies"}); its sources are sent
-- with the request as they would be by the lawspec CLI.
--
-- With stubs, a regenerated stub that differs fails the suite (review the
-- adapter's signature), and the bare stub is itself a mutant that must fail.
-- With architecture, a profile whose width differs from the host must be
-- rejected by native machine-sized adapters (Go, Haskell, Rust).
--
-- LAWSPEC_MACHINE_BITS=32 and LAWSPEC_MINIFY=1 select the profile; output goes
-- to .artifacts/<suite>[32][-compact]/<target>.
--
-- A passing run is recorded under .artifacts/cache/acceptance, keyed by the
-- generated project and everything else its tests read (see Cache). An
-- unchanged project reuses the result; LAWSPEC_CACHE=refresh runs everything
-- and records it, and LAWSPEC_CACHE=0 neither reads nor records.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (filterM, foldM, forM, forM_, unless, when)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort, stripPrefix)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.Directory
import System.Environment (getArgs, getEnvironment, lookupEnv)
import System.Exit (ExitCode(..), die, exitFailure)
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, readFile', stderr)
import System.Process (CreateProcess(..), proc, readCreateProcessWithExitCode)
import LawSpec.Api (dispatch)
import LawSpec.Scaffold (scaffoldFilesWith, scaffoldTargets)
import LawSpec.BuiltinDefaults (adapterPath)
import Toolchain
import Cache

data Generated = Generated { generatedPath :: FilePath, generatedContent :: String, generatedOwnership :: String }

-- | Each expectation is a set of alternatives, one of which the failing
-- output must contain (the diagnostic that exposed the mutant). A mutant
-- rejected at compile time (an end used twice, under Rust's moves) must fail
-- to compile; any other must compile and fail its laws.
data Mutant = Mutant
  { mutantName :: String, mutantExpect :: [[String]], mutantEdits :: [(FilePath, String, String)]
  , mutantAtCompile :: Bool, mutantAtGeneration :: Bool }

main :: IO ()
main = do
  args <- getArgs
  (suite, flags, selected) <- case args of
    suite : rest -> pure (suite, filter ("--" `isPrefixOf`) rest, filter (not . ("--" `isPrefixOf`)) rest)
    [] -> die "usage: lawspec-acceptance <suite> [--check | --no-mutants] [target...]"
  let check = "--check" `elem` flags
      mutate = "--no-mutants" `notElem` flags
  bits <- maybe 64 read <$> lookupEnv "LAWSPEC_MACHINE_BITS"
  minify <- (== Just "1") <$> lookupEnv "LAWSPEC_MINIFY"
  manifest <- BL.readFile ("acceptance" </> suite </> "suite.json")
  specs <- case decode manifest >>= list . field "specs" of
    Just values -> pure [T.unpack s | String s <- values]
    Nothing -> die ("invalid acceptance/" ++ suite ++ "/suite.json")
  sources <- forM specs $ \path -> (,) path <$> readFile path
  vectors <- case field "vectors" <$> decode manifest of
    Just (String path) -> pure . conformance <$> BL.readFile (T.unpack path)
    _ -> pure []
  let architecture = (field "architecture" <$> decode manifest) == Just (Bool True)
  packages <- case decode manifest >>= list . field "packages" of
    Just values -> mapM (loadPackage . T.unpack) [s | String s <- values]
    Nothing -> pure []
  let dependencies = maybe (object []) (field "dependencies") (decode manifest)
      extra = [("packages", toJSON packages) | not (null packages)] ++
        [("dependencies", dependencies) | dependencies /= Null]
  let targets = if null selected then scaffoldTargets else selected
      profile = (if bits == 32 then "32" else "") ++ (if minify then "-compact" else "")
  forM_ targets $ \target -> do
    let project = ".artifacts" </> (suite ++ profile) </> target
        bindingsFile = "acceptance" </> suite </> target </> "bindings.json"
    -- A target's native bindings, sent as the CLI sends lawspec.json's.
    hasBindings <- doesFileExist bindingsFile
    bound <- if hasBindings then decode <$> BL.readFile bindingsFile else pure Nothing
    let native = maybe [] (\b -> [("nativeBindings", b), ("schemaVersion", toJSON (4 :: Int))]) bound
    generated <- plan (extra ++ native) (sources ++ vectors) target bits minify
    if check then checkDisk project generated else do
      writeProject suite target project (bits == 64 && not minify) minify generated
      mismatch <- if architecture then architectureMismatch target bits else pure False
      if mismatch then expectMismatch target bits project
      else do
        mode <- cacheMode
        scaffolds <- either die pure (scaffoldFilesWith (usesCrypto target generated) minify target)
        suiteInputs <- fmap concat $ forM ["acceptance" </> suite </> target, "acceptance" </> suite </> "mutants"] $ \base ->
          doesDirectoryExist base >>= \exists -> if exists then walk base else pure []
        recordingInputs <- map snd <$> suiteRecordings suite
        key <- runKey target [suite, target, profile, show mutate]
          (scaffolds ++ [(generatedPath g, generatedContent g) | g <- generated])
          (suiteInputs ++ recordingInputs ++ harnessInputs target)
        recorded <- if mode == Reuse then lookupResult key else pure Nothing
        case recorded of
          Just output -> mapM_ (putStrLn . (++ " (cached)")) output
          Nothing -> do
            let regenerate edited = planEither (extra ++ native) (edited ++ vectors) target bits minify
            output <- runSuite suite target project mutate (sources, regenerate, generated)
            when (mode /= Off) (storeResult key output)

-- | Files outside the project that a run reads: the harness itself and the
-- dependency locks it installs.
harnessInputs :: String -> [FilePath]
harnessInputs target =
  [ "acceptance/Main.hs", "acceptance/Toolchain.hs", "acceptance/Cache.hs", "test/locks/go/go.sum"
  , ".integration" </> target </> "package.json", ".integration" </> target </> "package-lock.json" ] ++
  ["test/locks" </> target </> lock | Just lock <- [beamLock target]]

beamLock :: String -> Maybe FilePath
beamLock target = lookup target [("erlang","rebar.lock"),("elixir","mix.lock"),("gleam","manifest.toml")]

-- | Generation goes through the same JSON boundary that core.wasm exports.
plan :: [(K.Key, Value)] -> [(FilePath, String)] -> String -> Int -> Bool -> IO [Generated]
plan extra sources target bits minify =
  either (\message -> die (target ++ ": generation failed: " ++ message)) pure (planEither extra sources target bits minify)

planEither :: [(K.Key, Value)] -> [(FilePath, String)] -> String -> Int -> Bool -> Either String [Generated]
planEither extra sources target bits minify = do
  let request = object $
        [ "method" .= ("planGeneration" :: String), "target" .= target, "machineBits" .= bits, "minify" .= minify
        , "sources" .= [object ["path" .= takeName path, "content" .= content] | (path, content) <- sources] ] ++ extra
      response = fromMaybe Null (decode (dispatch (encode request)))
  case list (field "diagnostics" response) of
    Just [] -> pure ()
    _ -> Left (show (encode (field "diagnostics" response)))
  pure [ Generated (text (field "path" f)) (text (field "content" f)) (text (field "ownership" f))
       | f <- fromMaybe [] (list (field "files" response)) ]
  where takeName = reverse . takeWhile (/= '/') . reverse

-- | A package as the lawspec CLI sends it: its manifest with the sources read.
loadPackage :: FilePath -> IO Value
loadPackage directory = do
  manifest <- BL.readFile (directory </> "lawspec-package.json")
  value <- maybe (die ("invalid " ++ directory ++ "/lawspec-package.json")) pure (decode manifest)
  let roots = [T.unpack s | String s <- fromMaybe [] (list (field "sources" value))]
  files <- concat <$> mapM (lawspecFiles . (directory </>)) roots
  sources <- forM (sort files) $ \path -> do
    content <- readFile path
    pure (object ["path" .= path, "content" .= content])
  case value of
    Object o -> pure (Object (KM.insert "sources" (toJSON sources) o))
    _ -> die ("invalid " ++ directory ++ "/lawspec-package.json")
  where
    lawspecFiles path = do
      isDirectory <- doesDirectoryExist path
      if isDirectory
        then do
          entries <- sort <$> listDirectory path
          concat <$> mapM (lawspecFiles . (path </>)) entries
        else pure [path | ".lawspec" `isSuffixOf` path]

-- The crypto libraries only for programs that import lawspec.crypto or
-- lawspec.network (or, in Haskell and Rust, lawspec.randomness, whose secure
-- generator comes from them), as lawspec init and the setup advice say.
usesCrypto :: String -> [Generated] -> Bool
usesCrypto target = any (\g -> generatedPath g == adapterPath target "lawspec.crypto"
  || (target `elem` ["haskell", "rust"] && generatedPath g == adapterPath target "lawspec.randomness")
  || any (`isInfixOf` generatedPath g) ["lawspec_network.", "LawSpecNetwork.", "src/lawspec/network.rs"])

writeProject :: String -> String -> FilePath -> Bool -> Bool -> [Generated] -> IO ()
writeProject suite target project defaultProfile minify generated = do
  createDirectoryIfMissing True project
  forM_ ["src", "lib", "test", "tests", "example", "dist", "lawspec"] $ \folder -> removePathForcibly (project </> folder)
  scaffolds <- either die pure (scaffoldFilesWith (usesCrypto target generated) minify target)
  forM_ scaffolds $ \(path, content) -> writeAt (project </> path) content
  forM_ generated $ \g -> writeAt (project </> generatedPath g) (generatedContent g)
  adapters <- suiteFiles suite target
  -- An adapter may only replace a generated user-owned file, so a renamed or
  -- removed stub cannot leave a stale adapter unnoticed.
  forM_ adapters $ \(relative, source) -> do
    unless (relative `elem` [generatedPath g | g <- generated, generatedOwnership g == "user"])
      (die (target ++ ": adapter " ++ relative ++ " does not replace a generated user-owned file"))
    readFile source >>= writeAt (project </> relative)
  natives <- suiteDirectory suite target "native"
  forM_ natives $ \(relative, source) -> readFile source >>= writeAt (project </> relative)
  -- Recorded values are spec data, the same for every target.
  removePathForcibly (project </> "recorded")
  recordings <- suiteRecordings suite
  forM_ recordings $ \(relative, source) -> readFile' source >>= writeAt (project </> relative)
  -- Stubs depend on the profile, so they are compared in the default one.
  when defaultProfile $ forM_ adapters $ \(relative, _) -> do
    let recorded = "acceptance" </> suite </> target </> "stubs" </> relative
    exists <- doesFileExist recorded
    when exists $ do
      expected <- readFile' recorded
      unless (Just expected == lookup relative [(generatedPath g, generatedContent g) | g <- generated])
        (die (target ++ ": the generated stub for " ++ relative ++ " changed; review the adapter and update " ++ recorded))
  root <- getCurrentDirectory
  when (target `elem` ["javascript", "typescript"]) $ do
    let link = project </> "node_modules"
    exists <- doesPathExist link
    unless exists (createDirectoryLink (root </> ".integration" </> target </> "node_modules") link)
  when (target == "go") (copyFile "test/locks/go/go.sum" (project </> "go.sum"))
  forM_ (beamLock target) $ \lock -> copyFile ("test/locks" </> target </> lock) (project </> lock)
  when (target == "elixir") $ do
    let link = project </> "deps"
    exists <- doesPathExist link
    unless exists (createDirectoryLink (root </> ".integration/elixir/deps") link)

-- A suite's recorded values: acceptance/<suite>/recorded/<unit>/<name>, as
-- recorded/<unit>/<name> in each project.
suiteRecordings :: String -> IO [(FilePath, FilePath)]
suiteRecordings suite = do
  let base = "acceptance" </> suite </> "recorded"
  exists <- doesDirectoryExist base
  files <- if exists then walk base else pure []
  pure [("recorded" </> drop (length base + 1) file, file) | file <- files]

-- | The lines printed for a passing run.
runSuite :: String -> String -> FilePath -> Bool -> ([(FilePath, String)], [(FilePath, String)] -> Either String [Generated], [Generated]) -> IO [String]
runSuite suite target project mutate (sources, regenerate, generated) = do
  tool <- toolchain project target
  (code, output) <- runTool tool (arguments tool) project
  writeFile (project </> "correct.log") output
  when (code /= ExitSuccess) $ do
    hPutStrLn stderr (target ++ ": correct adapters failed (see " ++ project </> "correct.log)")
    exitFailure
  let passed = target ++ ": " ++ suite ++ " passes"
  putStrLn passed
  -- A suite with "schedule": true checks how the harness ran it.
  manifest <- BL.readFile ("acceptance" </> suite </> "suite.json")
  scheduled <- if (field "schedule" <$> decode manifest) == Just (Bool True) then pure <$> checkSchedule target tool project else pure []
  mutants <- if mutate then suiteMutants suite target else pure []
  stubs <- if mutate then suiteStubs suite target else pure []
  -- Mutants edit adapters, or the native code a bound unit calls.
  adapters <- (++) <$> suiteFiles suite target <*> suiteDirectory suite target "native"
  let restore = forM_ adapters $ \(relative, source) -> readFile source >>= writeAt (project </> relative)
  rejected <- flip finally restore $ forM (stubs ++ mutants) $ \mutant -> do
    restore
    forM_ (mutantEdits mutant) $ \(relative, search, replacement) -> do
      unless (relative `elem` map fst adapters)
        (die (target ++ ": mutant " ++ mutantName mutant ++ " must edit an adapter, not " ++ relative))
      original <- readFile' (project </> relative)
      case if search == "*" then Just replacement else replaceOnce search replacement original of
        Just changed -> writeAt (project </> relative) changed
        Nothing -> die (target ++ ": mutant " ++ mutantName mutant ++ " does not match " ++ relative)
    (mutantCode, mutantOutput) <- runTool tool (mutantArguments target (arguments tool)) project
    writeFile (project </> ("mutant-" ++ mutantName mutant ++ ".log")) mutantOutput
    when (mutantCode == ExitSuccess) (die (target ++ ": mutant " ++ mutantName mutant ++ " escaped detection"))
    when (compileFailure mutantOutput /= mutantAtCompile mutant)
      (die (target ++ ": mutant " ++ mutantName mutant ++
        (if mutantAtCompile mutant then " compiled" else " failed to compile") ++ " (see log)"))
    forM_ (mutantExpect mutant) $ \alternatives ->
      unless (any (`isInfixOf` mutantOutput) alternatives)
        (die (target ++ ": mutant " ++ mutantName mutant ++ " failed without " ++ show alternatives))
    let line = target ++ ": rejected " ++ mutantName mutant
    putStrLn line
    pure line
  -- Spec mutants edit a spec, so the project is regenerated for each.
  specMutants <- if mutate then suiteMutantsIn ("acceptance" </> suite </> "mutants") else pure []
  let compilerOwned gs = [g | g <- gs, generatedOwnership g /= "user"]
      writeGenerated gs = forM_ (compilerOwned gs) $ \g -> writeAt (project </> generatedPath g) (generatedContent g)
  specRejected <- flip finally (writeGenerated generated) $ forM specMutants $ \mutant -> do
    edited <- forM sources $ \(path, content) -> do
      let edits = [(search, replacement) | (relative, search, replacement) <- mutantEdits mutant, relative == path]
      changed <- foldM (\text (search, replacement) -> maybe
        (die (target ++ ": spec mutant " ++ mutantName mutant ++ " does not match " ++ path)) pure
        (replaceOnce search replacement text)) content edits
      pure (path, changed)
    forM_ (mutantEdits mutant) $ \(relative, _, _) -> unless (relative `elem` map fst sources)
      (die (target ++ ": spec mutant " ++ mutantName mutant ++ " must edit a spec of the suite, not " ++ relative))
    output <- case regenerate edited of
      Left diagnostics -> do
        unless (mutantAtGeneration mutant)
          (die (target ++ ": spec mutant " ++ mutantName mutant ++ " was rejected by the compiler: " ++ diagnostics))
        pure diagnostics
      Right regenerated -> do
        when (mutantAtGeneration mutant)
          (die (target ++ ": spec mutant " ++ mutantName mutant ++ " compiled"))
        writeGenerated regenerated
        (mutantCode, mutantOutput) <- runTool tool (mutantArguments target (arguments tool)) project
        writeFile (project </> ("mutant-" ++ mutantName mutant ++ ".log")) mutantOutput
        when (mutantCode == ExitSuccess) (die (target ++ ": spec mutant " ++ mutantName mutant ++ " escaped detection"))
        writeGenerated generated
        pure mutantOutput
    forM_ (mutantExpect mutant) $ \alternatives ->
      unless (any (`isInfixOf` output) alternatives)
        (die (target ++ ": spec mutant " ++ mutantName mutant ++ " failed without " ++ show alternatives))
    let line = target ++ ": rejected " ++ mutantName mutant
    putStrLn line
    pure line
  pure (passed : scheduled ++ rejected ++ specRejected)

-- | Regenerate without running anything and compare with the files on disk.
checkDisk :: FilePath -> [Generated] -> IO ()
checkDisk project generated = do
  -- User-owned files hold adapters, so only compiler-owned output is compared.
  stale <- filterM (\g -> do
    let path = project </> generatedPath g
    exists <- doesFileExist path
    if exists then (/= generatedContent g) <$> readFile' path else pure True)
    [g | g <- generated, generatedOwnership g /= "user"]
  unless (null stale) (die ("stale generated files: " ++ unwords (map generatedPath stale)))
  putStrLn (project ++ ": generated files match")

-- The scheduling checks: the adapters note when each call starts and ends
-- (LAWSPEC_SCHEDULE_LOG). `order random` must follow the run's seed (the
-- same seed, the same order; another seed, another order) in the unit that
-- calls pause (arguments below 100), and the `parallel` unit's naps (from
-- 100) must overlap.
checkSchedule :: String -> Toolchain -> FilePath -> IO String
checkSchedule target tool project = do
  root <- getCurrentDirectory
  let logFile = root </> project </> "schedule.log"
      runWith seed = do
        removePathForcibly logFile
        -- Gradle would skip a test task whose inputs did not change.
        let rerun = ["--rerun" | target == "kotlin"]
        (code, output) <- runToolWith [("LAWSPEC_SEED", show seed), ("LAWSPEC_SCHEDULE_LOG", logFile)] tool (arguments tool ++ rerun) project
        writeFile (project </> ("schedule-" ++ show seed ++ ".log")) output
        unless (code == ExitSuccess) (die (target ++ ": the run with seed " ++ show seed ++ " failed (see " ++ project </> "schedule-" ++ show seed ++ ".log)"))
        content <- readFile' logFile
        pure [(event, read n :: Int, read t :: Double) | [event, n, t] <- map words (lines content)]
      order events = nub [n | ("start", n, _) <- events, n < 100]
      naps events = [(n, start, end) | ("start", n, start) <- events, n >= 100, ("end", m, end) <- events, m == n]
      overlapping events = or [s1 < e2 && s2 < e1 | (n1, s1, e1) <- naps events, (n2, s2, e2) <- naps events, n1 /= n2]
  first <- runWith (11 :: Int)
  again <- runWith 11
  unless (length (order first) == 6)
    (die (target ++ ": order random: expected six pauses, found " ++ show (order first)))
  unless (order first == order again)
    (die (target ++ ": order random with seed 11 ran " ++ show (order first) ++ ", then " ++ show (order again)))
  let differing [] = pure Nothing
      differing (seed : rest) = do
        events <- runWith seed
        if order events /= order first then pure (Just (seed, order events)) else differing rest
  other <- differing [12 .. 16 :: Int]
  case other of
    Nothing -> die (target ++ ": order random gave " ++ show (order first) ++ " for seeds 11 to 16")
    Just _ -> pure ()
  unless (overlapping first && overlapping again)
    (die (target ++ ": parallel: the naps did not overlap: " ++ show (naps first)))
  let line = target ++ ": order random follows the seed " ++ show (order first) ++ "; parallel laws overlap"
  putStrLn line
  pure line

runTool :: Toolchain -> [String] -> FilePath -> IO (ExitCode, String)
runTool = runToolWith []

runToolWith :: [(String, String)] -> Toolchain -> [String] -> FilePath -> IO (ExitCode, String)
runToolWith extra tool args project = do
  prepare tool
  environment <- getEnvironment
  let settings = if null extra then Nothing else Just (extra ++ [kv | kv@(k, _) <- environment, k `notElem` map fst extra])
  (code, out, err) <- readCreateProcessWithExitCode (proc (command tool) args) { cwd = Just project, env = settings } ""
  extra' <- report tool
  pure (code, out ++ err ++ extra')


suiteFiles :: String -> String -> IO [(FilePath, FilePath)]
suiteFiles suite target = suiteDirectory suite target "files"

suiteDirectory :: String -> String -> FilePath -> IO [(FilePath, FilePath)]
suiteDirectory suite target folder = do
  let base = "acceptance" </> suite </> target </> folder
  exists <- doesDirectoryExist base
  if not exists then pure [] else map (\path -> (dropBase base path, path)) <$> walk base
  where dropBase base path = fromMaybe path (stripPrefix (base ++ "/") path)

-- | The generated stub replaces the adapter wholesale: unimplemented functions
-- must fail the laws rather than pass vacuously.
suiteStubs :: String -> String -> IO [Mutant]
suiteStubs suite target = do
  let base = "acceptance" </> suite </> target </> "stubs"
  exists <- doesDirectoryExist base
  stubs <- if exists then walk base else pure []
  adapters <- suiteFiles suite target
  edits <- forM stubs $ \path -> do
    let relative = fromMaybe path (stripPrefix (base ++ "/") path)
    source <- maybe (die (path ++ ": no adapter for this stub")) pure (lookup relative adapters)
    (,,) relative <$> readFile' source <*> readFile' path
  pure [Mutant "stub" [] edits False False | not (null edits)]

-- | The conformance unit checks every shared scalar vector as a law.
conformance :: BL.ByteString -> (FilePath, String)
conformance bytes = ("conformance.lawspec", unlines ("unit conformance" :
  [ "law `vector " ++ show i ++ "` is definition is `for all` (marker :: Unit) . " ++
      text (field "expression" v) ++ " = " ++ text (field "expected" v) ++ " end end"
  | (i, v) <- zip [0 :: Int ..] (fromMaybe [] (decode bytes >>= list)) ]))

-- | Machine-sized native adapters check the executing architecture. The width
-- of the host comes from the toolchain that will run the tests.
architectureMismatch :: String -> Int -> IO Bool
architectureMismatch target bits
  | target `notElem` ["go", "haskell", "rust"] = pure False
  | otherwise = (/= bits) <$> nativeBits
  where
    nativeBits = case target of
      "rust" -> do
        cross <- lookupEnv "CARGO_BUILD_TARGET"
        (_, out, _) <- readCreateProcessWithExitCode
          (proc "rustc" (["--print", "cfg"] ++ maybe [] (\t -> ["--target", t]) cross)) ""
        pure (if "target_pointer_width=\"32\"" `elem` lines out then 32 else 64)
      "go" -> (\arch -> if arch == Just "386" then 32 else 64) <$> lookupEnv "GOARCH"
      _ -> pure 64

expectMismatch :: String -> Int -> FilePath -> IO ()
expectMismatch target bits project = do
  tool <- toolchain project target
  (code, output) <- runTool tool (arguments tool) project
  writeFile (project </> "architecture-mismatch.log") output
  when (code == ExitSuccess || not ("machineBits does not match native architecture" `isInfixOf` output))
    (die (target ++ ": missing architecture mismatch diagnostic"))
  putStrLn (target ++ ": " ++ show bits ++ "-bit profile rejected for the native machine adapter")

suiteMutants :: String -> String -> IO [Mutant]
suiteMutants suite target = suiteMutantsIn ("acceptance" </> suite </> target </> "mutants")

suiteMutantsIn :: FilePath -> IO [Mutant]
suiteMutantsIn base = do
  exists <- doesDirectoryExist base
  names <- if exists then sort . filter (".mutant" `isSuffixOf`) <$> listDirectory base else pure []
  forM names $ \name -> do
    content <- readFile' (base </> name)
    let (header, body) = span (not . ("@@ " `isPrefixOf`)) (lines content)
        atCompile = "rejected-at: compile" `elem` header
        atGeneration = "rejected-at: generation" `elem` header
    (expectations, edits) <- either (die . ((base </> name ++ ": ") ++)) pure
      (parseMutant (unlines (filter (`notElem` ["rejected-at: compile", "rejected-at: generation"]) header ++ body)))
    pure (Mutant (take (length name - length (".mutant" :: String)) name) expectations edits atCompile atGeneration)

-- | rejected-at: compile                                (optional)
-- expect: <text the failing output must contain>        (optional, repeatable)
-- expect-any: <alternative> | <alternative>            (optional, repeatable)
-- @@ <path>
-- <<<<<<<
-- text to find (exactly once), or * to replace the whole file
-- =======
-- replacement
-- >>>>>>>
parseMutant :: String -> Either String ([[String]], [(FilePath, String, String)])
parseMutant content = do
  let (header, body) = span (not . ("@@ " `isPrefixOf`)) (lines content)
  expectations <- mapM expectation (filter (not . all (== ' ')) header)
  edits <- go Nothing body
  pure (expectations, edits)
  where
    expectation line
      | Just text' <- stripPrefix "expect: " line = Right [text']
      | Just alternatives <- stripPrefix "expect-any: " line = Right (splitOn " | " alternatives)
      | otherwise = Left ("unexpected header line: " ++ line)
    splitOn separator = go' ""
      where go' current [] = [reverse current]
            go' current rest@(c : cs)
              | separator `isPrefixOf` rest = reverse current : go' "" (drop (length separator) rest)
              | otherwise = go' (c : current) cs
    go _ [] = Right []
    go _ (line : rest) | Just path <- stripPrefix "@@ " line = go (Just path) rest
    go (Just path) ("<<<<<<<" : rest) = do
      let (search, afterSearch) = break (== "=======") rest
      (replacement, afterReplacement) <- case afterSearch of
        _ : more -> Right (break (== ">>>>>>>") more)
        [] -> Left "missing ======="
      remaining <- case afterReplacement of
        _ : more -> Right more
        [] -> Left "missing >>>>>>>"
      ((path, joined search, joined replacement) :) <$> go (Just path) remaining
    go path (line : rest) | all (== ' ') line = go path rest
    go _ (line : _) = Left ("unexpected line: " ++ line)
    joined = foldr1' (\a b -> a ++ "\n" ++ b)
    foldr1' _ [] = ""
    foldr1' f xs = foldr1 f xs

replaceOnce :: String -> String -> String -> Maybe String
replaceOnce search replacement = go ""
  where
    go _ [] = Nothing
    go before rest@(c : cs)
      | search `isPrefixOf` rest = Just (reverse before ++ replacement ++ drop (length search) rest)
      | otherwise = go (c : before) cs

walk :: FilePath -> IO [FilePath]
walk dir = do
  entries <- sort <$> listDirectory dir
  concat <$> forM entries (\entry -> do
    let path = dir </> entry
    isDirectory <- doesDirectoryExist path
    if isDirectory then walk path else pure [path])

writeAt :: FilePath -> String -> IO ()
writeAt path content = do
  createDirectoryIfMissing True (takeDirectory path)
  writeFile path content

field :: String -> Value -> Value
field name (Object o) = fromMaybe Null (KM.lookup (K.fromString name) o)
field _ _ = Null

list :: Value -> Maybe [Value]
list (Array a) = Just (V.toList a)
list _ = Nothing

text :: Value -> String
text (String s) = T.unpack s
text _ = ""
