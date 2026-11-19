-- | The CLI entry every host runs: parse the invocation and run it over the
-- host's effects ("LawSpec.App.Cli"). An invocation that reaches behaviour
-- not ported yet is reported as 'NotPorted' before the command has written
-- or printed anything, so a host can run the legacy Node CLI instead and
-- nothing is printed or written twice.
-- ref:DEC-host-effect-abi ref:DEC-haskell-application-port
module LawSpec.App.Main
  ( Invocation (..),
    HostIdentity (..),
    CanonTool (..),
    CanonSource (..),
    Outcome (..),
    Compiler (..),
    lawspecMain,
    pureCompiler,
    hostCompiler,
    notPortedExitCode,
    notPortedMessage,
    decodeInvocation,
    encodeOutcome,
  )
where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as JSON
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Text as T
import LawSpec.Api (CacheBackend (..), dispatch, dispatchWithCache)
import LawSpec.App.Arguments
import LawSpec.App.Cli (cli, reportFailure, usageText)
import LawSpec.App.Command
import LawSpec.App.Json (Json (..))
import LawSpec.App.Project (removeCreatedState)
import LawSpec.Host.Codec (abiVersion)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, normalise)

data Outcome
  = -- | The command ran; this is its exit code.
    Completed Int
  | -- | The command has not been ported; nothing was written or printed.
    NotPorted String
  deriving (Eq, Show)

-- | The exit code of a CLI with no legacy CLI to fall back to (the native
-- executable) for a command that is not ported yet. The legacy Node CLI
-- exits with 0, 1 and 2 and Node itself with 1 to 14 and 128 plus a signal
-- number, so this is sysexits.h's EX_UNAVAILABLE ("a service is
-- unavailable"). It disappears with the last unported command.
notPortedExitCode :: Int
notPortedExitCode = 69

-- | The one line such a CLI prints on standard error.
notPortedMessage :: Invocation -> String -> String
notPortedMessage invocation reason =
  "lawspec: " ++ command ++ " is not available in the native CLI yet (" ++ reason ++ ")"
  where
    command = case parseArguments (invocationArguments invocation) of
      Right arguments | Just name <- verb arguments -> "'" ++ name ++ "'"
      _ -> "this invocation"

-- | The compiler without a persistent cache, as the in-memory fake runs it:
-- a request's cache directory is dropped, so nothing reaches the real disk.
pureCompiler :: (Applicative m) => Compiler m
pureCompiler = Compiler (\_ request -> pure (dispatch (withoutCache request)))
  where
    withoutCache bytes = case JSON.decode bytes of
      Just (Object fields) | KM.member "cacheDirectory" fields -> JSON.encode (Object (KM.delete "cacheDirectory" fields))
      _ -> bytes

-- | The compiler over an IO host: its cache entries are read and written
-- with the host's effects, under the command's policy.
hostCompiler :: Compiler IO
hostCompiler = Compiler $ \host request ->
  dispatchWithCache
    CacheBackend
      { cacheRead = \file -> perform host (ReadFile file) >>= either (throwIO . userError . errorMessage) pure,
        cacheWrite = \file bytes -> perform host (WriteFile Replace Nothing file (BL.toStrict bytes)) >>= either (throwIO . userError . errorMessage) pure
      }
    request

lawspecMain :: (Monad m) => Host m -> Compiler m -> Invocation -> m Outcome
lawspecMain host compiler invocation = case parseArguments (invocationArguments invocation) of
  Left problem -> do
    (_, _) <- runCommand (newSession host compiler) (usageError (invocationArguments invocation) problem)
    pure (Completed 1)
  Right arguments -> do
    (result, session) <- runCommand (newSession host compiler) (protectSession (invocationDirectory invocation) >> cli invocation arguments)
    case result of
      Right code -> pure (Completed code)
      Left (Unported reason)
        | not (sessionMutated session) -> pure (NotPorted reason)
        | otherwise -> Completed 70 <$ finish session (printError ("lawspec: internal error: " ++ reason ++ ", after the command performed effects"))
      Left (Aborted failure) -> Completed 1 <$ finish session (removeCreatedState >> reportFailure arguments failure)
  where
    finish session command = runCommand session command

-- | An unknown option or an option without its value: the problem, naming
-- the option, and the usage lines of the command, with the legacy CLI's
-- error exit code (1). The legacy CLI throws these from its top level, so
-- Node prints the exception's stack trace instead; this is the one
-- intended divergence from it (host-parity.mjs records it). Under --json
-- the problem is a diagnostic, as every other failure is.
usageError :: (Monad m) => [String] -> String -> Command m ()
usageError arguments problem
  | "--json" `elem` arguments =
      printJson (JObject [("diagnostics", JArray [JObject [("code", JString "usage"), ("message", JString problem), ("at", JNull)]])])
  | otherwise = printError ("lawspec: " ++ problem ++ "\n" ++ usage)
  where
    usage = case commandUsage of
      [] -> "Run lawspec help for the commands and their options."
      first : more -> intercalate "\n" (("Usage: " ++ first) : map ("       " ++) more)
    commandUsage = case arguments of
      name : _ | not ("-" `isPrefixOf` name) -> filter (mentions name) usageLines
      _ -> []
    -- "lawspec ..." lines of the help text, without their indentation.
    usageLines = [line | raw <- lines usageText, let line = dropWhile (== ' ') (stripPrefix' "Usage: " raw), "lawspec " `isPrefixOf` line]
    -- A line names a command first, or after " | ", as in
    -- "lawspec check ... | doctor | explain ...".
    mentions name line = any ((== [name]) . take 1 . words . stripPrefix' "lawspec ") (splitOn " | " line)
    stripPrefix' prefix text = if prefix `isPrefixOf` text then drop (length prefix) text else text
    splitOn separator text = go "" text
      where
        go part [] = [reverse part]
        go part rest@(c : more)
          | separator `isPrefixOf` rest = reverse part : go "" (drop (length separator) rest)
          | otherwise = go (c : part) more

-- | @{"abi":2,"argv":[...],"cwd":"/absolute"}@, with an optional "build":
-- the host's SHA-256 of the core module, which names the compiler cache's
-- folder for this build; an optional "host", @{"kind":..,"version":..}@,
-- which with the build identifies the host native test results ran under;
-- an optional "resources", the absolute directory of the package
-- resources the host ships (lawspec learn's assets); and an optional
-- "tools", whose "canon" is the Canon the host ships,
-- @{"command":["/abs/canon"],"presets":"/abs/presets"}@ ('CanonTool'), or
-- the one the core downloads for a host that ships none,
-- @{"download":{"platform":"linux-x64","cache":"/abs/cache"}}@.
-- Other tools are ignored.
decodeInvocation :: B.ByteString -> Either String Invocation
decodeInvocation bytes = do
  value <- JSON.eitherDecodeStrict bytes
  fields <- case value of
    Object fields -> Right fields
    _ -> Left "invocation must be an object"
  case KM.lookup "abi" fields of
    Just (Number version) | version == fromIntegral abiVersion -> Right ()
    _ -> Left ("invocation needs abi " ++ show abiVersion)
  arguments <- case KM.lookup "argv" fields of
    Just (Array items) -> mapM text (toList items)
    _ -> Left "argv must be an array of strings"
  directory <- case KM.lookup "cwd" fields of
    Just (String path) | isAbsolute (T.unpack path) -> Right (normalise (T.unpack path))
    _ -> Left "cwd must be an absolute path"
  build <- case KM.lookup "build" fields of
    Nothing -> Right Nothing
    Just (String digest) -> Right (Just (T.unpack digest))
    _ -> Left "build must be a string"
  host <- case KM.lookup "host" fields of
    Nothing -> Right Nothing
    Just (Object identity)
      | Just (String kind) <- KM.lookup "kind" identity,
        Just (String version') <- KM.lookup "version" identity ->
          Right (Just (HostIdentity (T.unpack kind) (T.unpack version')))
    _ -> Left "host must be an object with a kind and a version"
  resources <- case KM.lookup "resources" fields of
    Nothing -> Right Nothing
    Just (String path) | isAbsolute (T.unpack path) -> Right (Just (normalise (T.unpack path)))
    _ -> Left "resources must be an absolute path"
  canon <- case KM.lookup "tools" fields of
    Nothing -> Right Nothing
    Just (Object tools) -> case KM.lookup "canon" tools of
      Nothing -> Right Nothing
      Just (Object tool)
        | Just (Array items) <- KM.lookup "command" tool,
          Right command@(program : _) <- mapM text (toList items),
          isAbsolute program,
          Just (String presets) <- KM.lookup "presets" tool,
          isAbsolute (T.unpack presets) ->
            Right (Just (CanonShipped (CanonTool (normalise program : drop 1 command) (normalise (T.unpack presets)))))
        | Just (Object download) <- KM.lookup "download" tool,
          Just (String platform) <- KM.lookup "platform" download,
          Just (String cache) <- KM.lookup "cache" download,
          isAbsolute (T.unpack cache) ->
            Right (Just (CanonDownload (T.unpack platform) (normalise (T.unpack cache))))
      _ -> Left "tools.canon must be an object with a command (an absolute program and its arguments) and an absolute presets directory, or with a download naming a platform and an absolute cache directory"
    _ -> Left "tools must be an object"
  pure (Invocation arguments directory build host resources canon)
  where
    text (String item) = Right (T.unpack item)
    text _ = Left "argv must be an array of strings"

-- | @{"abi":2,"exit":n}@, @{"abi":2,"notPorted":"why"}@ or, for a malformed
-- invocation, @{"abi":2,"error":{"kind":"invalid","message":"..."}}@.
encodeOutcome :: Either String Outcome -> B.ByteString
encodeOutcome result =
  BL.toStrict . JSON.encode . object $
    ("abi" .= abiVersion) : case result of
      Right (Completed code) -> ["exit" .= code]
      Right (NotPorted reason) -> ["notPorted" .= reason]
      Left problem -> ["error" .= object ["kind" .= errorKindName Invalid, "message" .= problem]]
