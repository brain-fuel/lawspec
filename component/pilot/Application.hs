{-# LANGUAGE OverloadedStrings #-}

-- | LawSpec pilot using the generated typed interface. ref:DEC-host-sdk-direct-haskell
module Application (dispatch, format, formatFiles, prelude, selectVersions, echo, exercise) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as B
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Encoding
import Host
import qualified LawSpec.Api as Compiler
import qualified LawSpec.Authoring as Authoring
import qualified LawSpec.Common as Common
import qualified LawSpec.Component as Component
import LawSpec.Memo (CacheBackend (..), withCacheBackend)
import qualified LawSpec.Service.Formatting as Formatting

-- | The formatter calls the shared typed service directly. Diagnostics retain
-- exact positions and block opener ranges without a JSON reconstruction.
-- ref:DEC-haskell-application-port
format :: ApplicationFormatRequest -> IO (Either HostError ApplicationFormatResponse)
format (ApplicationFormatRequest sources compile) = checked $ case Formatting.formatStandalone (fromMaybe True compile) [Common.Source (T.unpack p) (T.unpack c) | ApplicationSource p c <- sources] of
  Formatting.FormatResult output diagnostics ->
    ApplicationFormatResponse
      [ApplicationSource (T.pack (Common.path source)) (T.pack (Common.content source)) | source <- output]
      (map diagnostic diagnostics)
      "1.0-rc.2"

-- | Project typed diagnostic constructors onto the generated WIT record.
diagnostic :: Common.Diagnostic -> ApplicationDiagnostic
diagnostic value =
  ApplicationDiagnostic
    (T.pack (Common.code value))
    (T.pack (Common.message value))
    (location <$> Common.at value)
    (case value of Common.BlockDiagnostic {Common.diagnosticSpan = range} -> Just (spanValue range); _ -> Nothing)
    ( case value of
        Common.BlockDiagnostic {Common.diagnosticOpener = Just opener} -> [ApplicationRelated "Block opened here." (spanValue opener)]
        _ -> []
    )

-- | Compiler source coordinates are positive scalar counts.
location :: Common.Location -> ApplicationLocation
location (Common.Location file line column) = ApplicationLocation (T.pack file) (fromIntegral line) (fromIntegral column)

-- | Preserve both ends of the compiler source range.
spanValue :: Common.Span -> ApplicationSpan
spanValue (Common.Span start end) = ApplicationSpan (location start) (location end)

-- | Force the complete response while exceptions can still become typed host
-- failures, rather than escaping later from lazy canonical ABI lowering.
checked :: (Show a) => a -> IO (Either HostError a)
checked value = do
  outcome <- try (evaluate (length (show value)))
  pure $ case outcome of
    Left err -> Left (HostError HostStatusFailed (T.pack (displayException (err :: SomeException))))
    Right _ -> Right value

-- | Discovery and version selection share the native compiler's typed services.
prelude :: ApplicationPreludeQuery -> IO (Either HostError ApplicationPreludeResult)
prelude query = checked $ case Authoring.queryPrelude request of
  Left problems -> ApplicationPreludeResultInvalid (map diagnostic problems)
  Right (Authoring.PreludeResult entries source) ->
    ApplicationPreludeResultCatalog
      (ApplicationPreludeResponse (map entry entries) (T.pack source))
  where
    request = case query of
      ApplicationPreludeQueryAll -> Authoring.PreludeAll
      ApplicationPreludeQueryMatching text -> Authoring.PreludeMatching (T.unpack text)
      ApplicationPreludeQueryInvalid -> Authoring.PreludeInvalid
    entry (Authoring.PreludeOperation name qualified definition) =
      ApplicationPreludeEntryOperation
        (ApplicationPreludeOperation (T.pack name) (T.pack qualified) (T.pack <$> definition))
    entry (Authoring.PreludeLaw name source) =
      ApplicationPreludeEntryLaw
        (ApplicationPreludeLaw (T.pack name) (T.pack source))

-- | Package version ordering and validation remain application decisions.
selectVersions :: ApplicationVersionsRequest -> IO (Either HostError ApplicationVersionsResponse)
selectVersions (ApplicationVersionsRequest range versions) = checked $ case Component.selectVersions (T.unpack range) (map T.unpack versions) of
  Component.VersionSelection problems selected -> ApplicationVersionsResponse (map T.pack problems) (map T.pack <$> selected)

-- | Exposes a text round trip to test initialization and canonical string ownership.
echo :: Text -> IO (Either HostError Text)
echo = pure . Right

-- | Brackets a granted resource while the imported operation can suspend.
exercise :: Text -> HostRequest -> IO (Either HostError Text)
exercise name request = do
  granted <- acquire name
  case granted of
    Left err -> pure (Left err)
    Right provider -> withHostProvider (pure provider) (\handle -> perform handle request)

-- | All inputs are read and formatted before the first write is attempted.
formatFiles :: ApplicationFilesRequest -> IO (Either HostError ApplicationFormatResponse)
formatFiles (ApplicationFilesRequest name paths write compile) = do
  granted <- acquire name
  case granted of
    Left err -> pure (Left err)
    Right provider -> withHostProvider (pure provider) $ \handle -> runExceptT $ do
      inputs <- traverse (\path -> ApplicationSource path <$> ExceptT (perform handle (HostRequestReadText path))) paths
      response <- ExceptT (format (ApplicationFormatRequest inputs compile))
      case response of
        ApplicationFormatResponse output [] _
          | fromMaybe False write ->
              traverse_ (\(ApplicationSource path text) -> ExceptT (perform handle (HostRequestWriteText (HostWriteRequest path text)))) output
        _ -> pure ()
      pure response

-- | Preserve the compiler's versioned JSON API while moving host access behind
-- the typed capability contract. Schema validation remains in LawSpec.Api.
-- ref:DEC-host-sdk-independent-consumer
dispatch :: Text -> IO (Either HostError Text)
dispatch request = do
  let bytes = B.fromStrict (Encoding.encodeUtf8 request)
      cached = case decode bytes of
        Just (Object fields) -> case KM.lookup "cacheDirectory" fields of
          Just (String directory) -> not (T.null directory)
          _ -> False
        _ -> False
      invoke backend = do
        outcome <- try $ withCacheBackend backend $ evaluate $ B.toStrict $ Compiler.dispatch bytes
        pure $ case outcome of
          Left err -> Left (HostError HostStatusFailed (T.pack (displayException (err :: SomeException))))
          Right result -> Right (Encoding.decodeUtf8 result)
      backend provider =
        CacheBackend
          { cacheRead = \path -> do
              result <- perform provider (HostRequestReadText (T.pack path))
              either (fail . show) (either fail pure . Base64.decode . Encoding.encodeUtf8) result,
            cacheWrite = \path value -> do
              result <- perform provider (HostRequestWriteText (HostWriteRequest (T.pack path) (Encoding.decodeUtf8 (Base64.encode (B.toStrict value)))))
              either (fail . show) (const (pure ())) result
          }
  if cached
    then do
      granted <- acquire "compiler-cache"
      case granted of
        Left _ -> invoke Nothing
        Right provider -> withHostProvider (pure provider) (invoke . Just . backend)
    else invoke Nothing
