-- | The native LawSpec CLI: the Haskell application over the native IO host
-- interpreter. It is the JVM packages' platform binary and the reference in
-- host parity runs. A command that is not ported yet is reported in one
-- line and exits with 'notPortedExitCode', since there is no legacy CLI to
-- fall back to here. With --api <method> it answers one compiler API
-- request instead (the request object on standard input, the response on
-- standard output), as createCompiler() does in the npm package and
-- lawspec_call in the WebAssembly core; the JVM launcher's compiler API is
-- thin process calls to it.
-- ref:DEC-host-effect-abi ref:DEC-jvm-native-host
module Main (main) where

import Control.Monad (mfilter)
import qualified Data.Aeson as JSON
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import LawSpec.Api (dispatch)
import Data.Version (showVersion)
import LawSpec.App.Main (CanonSource (..), CanonTool (..), HostIdentity (..), Invocation (..), Outcome (..), hostCompiler, lawspecMain, notPortedExitCode, notPortedMessage)
import LawSpec.Host.Conformance (conformance, conformant, renderVerdicts)
import LawSpec.Host.Native (nativeHost)
import LawSpec.Host.Path (normalise)
import Paths_lawspec (version)
import System.Directory (getCurrentDirectory, makeAbsolute)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  arguments <- getArgs
  host <- nativeHost
  case arguments of
    -- The host conformance suite, outside the CLI's own command set.
    ["--host-conformance", scratch] -> do
      directory <- makeAbsolute scratch
      checks <- conformance host (normalise directory)
      putStr (renderVerdicts checks)
      exitWith (if conformant checks then ExitSuccess else ExitFailure 1)
    -- One compiler API request: the method named, schema version 5 unless
    -- the request names its own, as createCompiler() sends them.
    ["--api", method] -> do
      request <- BL.getContents
      BL.putStr (dispatch (apiRequest method request))
    _ -> do
      directory <- getCurrentDirectory
      -- The package resources (lawspec learn's assets) are wherever
      -- LAWSPEC_RESOURCES names; the native CLI ships none of its own.
      resources <- lookupEnv "LAWSPEC_RESOURCES" >>= traverse makeAbsolute . mfilter (not . null)
      -- The Canon bundle (tools/build-canon.sh: the canon executable and
      -- Rice's Tax's presets) is wherever LAWSPEC_CANON names; the JVM
      -- launcher sets it to the one its platform jar carries.
      canon <- lookupEnv "LAWSPEC_CANON" >>= traverse makeAbsolute . mfilter (not . null)
      -- The native CLI is its own core: no module digest, so the build is
      -- its version's digest ("LawSpec.App.Project" buildDigest).
      let invocation =
            Invocation
              arguments
              (normalise directory)
              Nothing
              (Just (HostIdentity "native" (showVersion version)))
              (normalise <$> resources)
              (CanonShipped . canonBundle . normalise <$> canon)
      outcome <- lawspecMain host hostCompiler invocation
      case outcome of
        Completed 0 -> exitWith ExitSuccess
        Completed code -> exitWith (ExitFailure code)
        NotPorted reason -> do
          hPutStrLn stderr (notPortedMessage invocation reason)
          exitWith (ExitFailure notPortedExitCode)

-- | The Canon in a bundle directory: its canon executable and presets.
canonBundle :: FilePath -> CanonTool
canonBundle directory = CanonTool [directory ++ "/canon"] (directory ++ "/presets")

-- | The request createCompiler() sends for a method: {schemaVersion: 5,
-- ...input, method}. Anything but a JSON object goes to 'dispatch' as it
-- is, which reports it.
apiRequest :: String -> BL.ByteString -> BL.ByteString
apiRequest method request = case JSON.decode request of
  Just (JSON.Object input) ->
    JSON.encode (JSON.Object (KM.insert "method" (JSON.toJSON method) (KM.union input (KM.singleton "schemaVersion" (JSON.Number 5)))))
  _ -> request
