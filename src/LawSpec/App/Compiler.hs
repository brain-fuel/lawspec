-- | Calls into the compiler, as the Node CLI makes them through api.mjs:
-- each request is the input with schemaVersion 5 and the method, and each
-- response is read as JavaScript reads it. 'diagnostics' is the Node CLI's
-- function of that name: it prints new warnings and fails on diagnostics.
-- ref:DEC-haskell-application-port ref:DEC-incremental-compilation
module LawSpec.App.Compiler
  ( call,
    callRaw,
    callOrdered,
    diagnostics,
    cacheWarning,
    diagnosticText,
  )
where

import Control.Monad (forM_, unless)
import qualified Data.Aeson as JSON
import qualified Data.ByteString.Lazy as BL
import Data.List (intercalate)
import qualified Data.Set as S
import LawSpec.App.Command
import LawSpec.App.Json

-- | One request through the session's compiler. A response naming a cache
-- entry the compiler could not store is reported once per run, on standard
-- error, and the field is removed (reportingCache in the Node CLI).
call :: (Monad m) => String -> Json -> Command m Json
call method input = do
  response <- callRaw method input
  case member "cacheFailure" response of
    Nothing -> pure response
    Just failure -> do
      session <- getSession
      unless (sessionCacheWarned session) (printError (cacheWarning failure))
      modifySession (\s -> s {sessionCacheWarned = True})
      pure (dropMember "cacheFailure" response)

-- | A request without the cache report.
callRaw :: (Monad m) => String -> Json -> Command m Json
callRaw method input = do
  session <- getSession
  host <- sessionHost
  let request = jsObject ([("schemaVersion", integer 5)] ++ members input ++ [("method", JString method)])
  bytes <- liftBase (compile (sessionCompiler session) host (JSON.encode (toValue request)))
  maybe (failWith "The compiler returned malformed JSON") (pure . fromValue) (JSON.decode bytes)

-- | A request whose response is read in the compiler's own member order,
-- as JSON.parse reads it, for a response written back out as it came: some
-- of the compiler's objects (the advice rows) are not in key order.
callOrdered :: (Monad m) => String -> Json -> Command m Json
callOrdered method input = do
  session <- getSession
  host <- sessionHost
  let request = jsObject ([("schemaVersion", integer 5)] ++ members input ++ [("method", JString method)])
  bytes <- liftBase (compile (sessionCompiler session) host (JSON.encode (toValue request)))
  either (const (failWith "The compiler returned malformed JSON")) pure (parseJson (fromUtf8 (BL.toStrict bytes)))

-- | compiler-cache.mjs cacheWarning, for a POSIX platform.
cacheWarning :: Json -> String
cacheWarning failure =
  "lawspec: warning: the compiler cache is not being written, so later runs repeat this work. "
    ++ text "reason"
    ++ " (path of "
    ++ show (length (text "path"))
    ++ " characters: "
    ++ text "path"
    ++ ")\nRun lawspec doctor to check the cache directory, or pass --no-cache."
  where
    text key = maybe "undefined" jsString (member key failure)

-- | diagnostics(result): print each warning not printed yet (unless --json),
-- then fail with every diagnostic, one per line.
diagnostics :: (Monad m) => Bool -> Json -> Command m Json
diagnostics json result = do
  unless json $
    forM_ (maybe [] id (member "warnings" result >>= arrayOf)) $ \warning -> do
      let message = located warning ++ "warning " ++ field "code" warning ++ ": " ++ field "message" warning
      seen <- sessionWarnings <$> getSession
      unless (S.member message seen) $ do
        printError message
        modifySession (\s -> s {sessionWarnings = S.insert message (sessionWarnings s)})
  case member "diagnostics" result of
    Just items@(JArray (_ : _)) -> failWithDiagnostics (intercalate "\n" (map diagnosticText (maybe [] id (arrayOf items)))) items
    _ -> pure result

-- | One diagnostic as the Node CLI words it.
diagnosticText :: Json -> String
diagnosticText item = located item ++ field "code" item ++ ": " ++ field "message" item

located :: Json -> String
located item = case member "at" item of
  Just at | isTruthy at -> field "file" at ++ ":" ++ field "line" at ++ ":" ++ field "column" at ++ ": "
  _ -> ""

-- | A field as a JavaScript template literal shows it.
field :: String -> Json -> String
field name value = maybe "undefined" jsString (member name value)
