-- | Content-addressed acceptance results. A run has two keys. The bytes key
-- hashes everything the native test tool reads: the generated project, the
-- suite's adapters, stubs and mutants, the harness itself, and the
-- toolchain's versions, dependency locks and environment. A compiler change
-- that leaves a target's output unchanged therefore reuses that target's
-- result instead of rerunning its tests (an early cutoff, as Salsa and
-- rustc's red-green algorithm do). The meaning key replaces the generated
-- project with the semantic hashes of its laws and declarations and the
-- compiler build, so a reformat, a rename or a doc edit in a suite's spec
-- reuses the result too (ref:DEC-content-identity). A pass is recorded
-- under both. LAWSPEC_CACHE=0 disables the cache, and LAWSPEC_CACHE=refresh
-- runs everything but still records passes.
--
-- The records live in the machine's shared development cache
-- (LAWSPEC_DEV_CACHE, by default ~/.cache/lawspec-dev, as dev/Ci/Cache.hs
-- resolves it), so every worktree reuses a pass any of them recorded. A key
-- therefore holds nothing of the worktree it was computed in: files enter
-- it by their paths from the repository root, and tools by what they report,
-- not by where they are installed. Records are written beside their final
-- name and renamed into place, since several runs write the store at once.
module Cache (Key, Mode(..), cacheMode, runKey, meaningKey, lookupResult, storeResult, sharedCache) where

import Control.Exception (IOException, onException, try)
import Control.Monad (filterM, forM)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, hPutStr, openTempFile, readFile')
import System.Process (proc, readCreateProcessWithExitCode)
import Text.Printf (printf)

newtype Key = Key String

-- | The machine's shared development cache.
sharedCache :: IO FilePath
sharedCache = do
  configured <- lookupEnv "LAWSPEC_DEV_CACHE"
  case configured of
    Just directory | not (null directory) -> makeAbsolute directory
    _ -> (</> ".cache/lawspec-dev") <$> getHomeDirectory

store :: IO FilePath
store = (</> "acceptance") <$> sharedCache

data Mode = Off | Refresh | Reuse deriving Eq

cacheMode :: IO Mode
cacheMode = lookupEnv "LAWSPEC_CACHE" >>= \case
  Just "0" -> pure Off
  Just "refresh" -> pure Refresh
  _ -> pure Reuse

-- | The labels name the run (suite, target, profile, mode); the contents are the
-- project files as written; the paths are further files the run reads.
runKey :: String -> [String] -> [(FilePath, String)] -> [FilePath] -> IO Key
runKey target = runKeyWith target environmentNames

runKeyWith :: String -> [String] -> [String] -> [(FilePath, String)] -> [FilePath] -> IO Key
runKeyWith target environmentNames labels contents paths = do
  existing <- filterM doesFileExist paths
  files <- forM (sort existing) $ \path -> (,) path <$> B.readFile path
  tools <- toolFingerprint target
  environment <- forM environmentNames $ \name -> maybe "" id <$> lookupEnv name
  let pieces = map utf8 ("lawspec-acceptance-cache-2" : labels ++ environment ++ tools) ++
        concat [[utf8 path, utf8 content] | (path, content) <- sort contents] ++
        concat [[utf8 path, bytes] | (path, bytes) <- files]
      digest = SHA.finalize (SHA.updates SHA.init (concatMap framed pieces))
  pure (Key (concatMap (printf "%02x") (B.unpack digest)))

-- | The meaning key: as runKey, with the compiler build and the semantic
-- hashes of what the project was generated from in place of its files.
meaningKey :: String -> [String] -> String -> [String] -> [(FilePath, String)] -> [FilePath] -> IO Key
meaningKey target labels build semantic contents paths =
  runKeyWith target (filter (/= "LAWSPEC_MINIFY") environmentNames) ("lawspec-acceptance-meaning-4" : build : labels ++ semantic) contents paths

utf8 :: String -> B.ByteString
utf8 = T.encodeUtf8 . T.pack

-- Length-prefixed, so no two different inputs share a byte stream.
framed :: B.ByteString -> [B.ByteString]
framed piece = [BC.pack (show (B.length piece) ++ ":"), piece]

-- | Environment that changes what a native test run does.
environmentNames :: [String]
environmentNames =
  [ "LAWSPEC_MACHINE_BITS", "LAWSPEC_MINIFY", "LAWSPEC_RUST_RELEASE", "LAWSPEC_PYTHON"
  , "RUSTUP_TOOLCHAIN", "CARGO_BUILD_TARGET", "GOARCH", "PYTHONOPTIMIZE", "PYTEST_ADDOPTS" ]

-- | The versions of the tools a target's tests run with. A tool that cannot be
-- started contributes its error, so the key still changes when it appears.
--
-- Asking every tool costs seconds (Gradle, pip, Scala), and a run of
-- lawspec-dev ci starts hundreds of suites per target. It names a directory
-- for the run (LAWSPEC_CI_TOOL_FINGERPRINTS) where the first suite of a
-- target leaves its answer for the others: the tools do not change while
-- one run lasts, and a target's suites start after its bootstrap has
-- finished. The answer is filed under the environment that selects tools.
toolFingerprint :: String -> IO [String]
toolFingerprint target = do
  shared <- lookupEnv "LAWSPEC_CI_TOOL_FINGERPRINTS"
  case shared of
    Just directory | not (null directory) -> do
      selection <- forM ("PATH" : environmentNames) $ \name -> fromMaybe "" <$> lookupEnv name
      let digest = SHA.finalize (SHA.updates SHA.init (concatMap (framed . utf8) (target : selection)))
          file = directory </> (target ++ "-" ++ concatMap (printf "%02x") (B.unpack digest))
      known <- try (readFile' file) :: IO (Either IOException String)
      case known >>= maybe (Left (userError "unreadable")) Right . readList' of
        Right tools -> pure tools
        Left _ -> do
          tools <- observeTools target
          -- Another suite may be leaving the same answer; either is whole.
          _ <- try (writeAtomically file (show tools)) :: IO (Either IOException ())
          pure tools
    _ -> observeTools target
  where
    readList' text = case reads text of
      [(tools, rest)] | all (`elem` (" \n" :: String)) rest -> Just tools
      _ -> Nothing

-- | Each tool is named by its role, not its location, and the worktree's own
-- path is taken out of what it prints: the pinned Python and Gradle live
-- under the worktree, and the same installation in another worktree is the
-- same tool.
observeTools :: String -> IO [String]
observeTools target = do
  root <- getCurrentDirectory
  python <- maybe (root </> ".integration" </> (if target=="prolog" then "prolog" else "python") </> ".venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
  let gradle = root </> ".tools/gradle-9.3.0/bin/gradle"
  local <- doesFileExist gradle
  mapM (version root) $ case target of
    "rust" -> [tool "rustc" ["-Vv"], tool "cargo" ["-V"]]
    "java" -> [tool "mvn" ["-v"]]
    t | t `elem` ["kotlin", "groovy"] -> [tool "java" ["-version"], ("gradle", if local then gradle else "gradle", ["--version", "--quiet"])]
    "python" -> [("python", python, ["--version"]), ("python", python, ["-m", "pip", "freeze", "--all"])]
    "prolog" -> [("python", python, ["--version"]), ("python", python, ["-c",
      "import importlib.metadata as m; import janus_swi as j; print(sorted((d.metadata['Name'], d.version) for d in m.distributions())); print(j.query_once('current_prolog_flag(version_data,V)')['V'])"])]
    "javascript" -> [tool "node" ["--version"]]
    "typescript" -> [tool "node" ["--version"]]
    "go" -> [tool "go" ["version"]]
    "haskell" -> [tool "stack" ["--version"]]
    "scala" -> [tool "java" ["-version"], tool "scala" ["version"]]
    "clojure" -> [tool "java" ["-version"], tool "clojure" ["--version"]]
    "swift" -> [tool "swift" ["--version"], tool "swift" ["format", "--version"]]
    _ -> []
  where
    tool program arguments = (program, program, arguments)
    version root (name, program, arguments) = do
      (_, out, err) <- readCreateProcessWithExitCode (proc program arguments) ""
      pure (unwords (name : arguments) ++ "\n" ++ withoutRoot root (out ++ err))
    withoutRoot root text = case text of
      [] -> []
      c : rest
        | root `isPrefixOf` text -> "<worktree>" ++ withoutRoot root (drop (length root) text)
        | otherwise -> c : withoutRoot root rest

-- | A recorded pass: the lines the run printed.
lookupResult :: Key -> IO (Maybe [String])
lookupResult (Key key) = do
  path <- (</> key) <$> store
  -- Another run may supersede the record at any moment, so reading it
  -- decides whether there is one.
  recorded <- try (readFile' path) :: IO (Either IOException String)
  pure (either (const Nothing) (Just . lines) recorded)

storeResult :: Key -> [String] -> IO ()
storeResult (Key key) output = do
  directory <- store
  createDirectoryIfMissing True directory
  writeAtomically (directory </> key) (unlines output)

-- | Write beside the file, then rename: a reader sees the whole content or
-- the previous one.
writeAtomically :: FilePath -> String -> IO ()
writeAtomically path content = do
  (temporary, handle) <- openTempFile (takeDirectory path) "record.tmp"
  (hPutStr handle content >> hClose handle >> renameFile temporary path)
    `onException` (hClose handle >> removePathForcibly temporary)
