-- | Content-addressed acceptance results. A run's key hashes everything the
-- native test tool reads: the generated project, the suite's adapters, stubs
-- and mutants, the harness itself, and the toolchain's versions, dependency
-- locks and environment. A compiler change that leaves a target's output
-- unchanged therefore reuses that target's result instead of rerunning its
-- tests (an early cutoff). LAWSPEC_CACHE=0 disables the cache, and
-- LAWSPEC_CACHE=refresh runs everything but still records passes.
module Cache (Key, Mode(..), cacheMode, runKey, lookupResult, storeResult) where

import Control.Monad (filterM, forM)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (readFile')
import System.Process (proc, readCreateProcessWithExitCode)
import Text.Printf (printf)

newtype Key = Key String

store :: FilePath
store = ".artifacts/cache/acceptance"

data Mode = Off | Refresh | Reuse deriving Eq

cacheMode :: IO Mode
cacheMode = lookupEnv "LAWSPEC_CACHE" >>= \case
  Just "0" -> pure Off
  Just "refresh" -> pure Refresh
  _ -> pure Reuse

-- | The labels name the run (suite, target, profile, mode); the contents are the
-- project files as written; the paths are further files the run reads.
runKey :: String -> [String] -> [(FilePath, String)] -> [FilePath] -> IO Key
runKey target labels contents paths = do
  existing <- filterM doesFileExist paths
  files <- forM (sort existing) $ \path -> (,) path <$> B.readFile path
  tools <- toolFingerprint target
  environment <- forM environmentNames $ \name -> maybe "" id <$> lookupEnv name
  let pieces = map utf8 ("lawspec-acceptance-cache-1" : labels ++ environment ++ tools) ++
        concat [[utf8 path, utf8 content] | (path, content) <- sort contents] ++
        concat [[utf8 path, bytes] | (path, bytes) <- files]
      digest = SHA.finalize (SHA.updates SHA.init (concatMap framed pieces))
  pure (Key (concatMap (printf "%02x") (B.unpack digest)))
  where
    utf8 = T.encodeUtf8 . T.pack
    -- Length-prefixed, so no two different inputs share a byte stream.
    framed piece = [BC.pack (show (B.length piece) ++ ":"), piece]

-- | Environment that changes what a native test run does.
environmentNames :: [String]
environmentNames =
  [ "LAWSPEC_MACHINE_BITS", "LAWSPEC_MINIFY", "LAWSPEC_RUST_RELEASE", "LAWSPEC_PYTHON"
  , "RUSTUP_TOOLCHAIN", "CARGO_BUILD_TARGET", "GOARCH" ]

-- | The versions of the tools a target's tests run with. A tool that cannot be
-- started contributes its error, so the key still changes when it appears.
toolFingerprint :: String -> IO [String]
toolFingerprint target = do
  root <- getCurrentDirectory
  python <- maybe (root </> ".integration/python/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
  let gradle = root </> ".tools/gradle-9.3.0/bin/gradle"
  local <- doesFileExist gradle
  mapM version $ case target of
    "rust" -> [("rustc", ["-Vv"]), ("cargo", ["-V"])]
    "java" -> [("mvn", ["-v"])]
    "kotlin" -> [("java", ["-version"]), (if local then gradle else "gradle", ["--version", "--quiet"])]
    "python" -> [(python, ["--version"]), (python, ["-m", "pip", "freeze", "--all"])]
    "javascript" -> [("node", ["--version"])]
    "typescript" -> [("node", ["--version"])]
    "go" -> [("go", ["version"])]
    "haskell" -> [("stack", ["--version"])]
    _ -> []
  where
    version (program, arguments) = do
      (_, out, err) <- readCreateProcessWithExitCode (proc program arguments) ""
      pure (unwords (program : arguments) ++ "\n" ++ out ++ err)

-- | A recorded pass: the lines the run printed.
lookupResult :: Key -> IO (Maybe [String])
lookupResult (Key key) = do
  let path = store </> key
  exists <- doesFileExist path
  if exists then Just . lines <$> readFile' path else pure Nothing

storeResult :: Key -> [String] -> IO ()
storeResult (Key key) output = do
  createDirectoryIfMissing True store
  writeFile (store </> key) (unlines output)
