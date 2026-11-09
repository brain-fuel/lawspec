-- | Schema-5 JSON adapter for shared manifest and version services. Admission
-- uses compiler-independent domain records before this adapter renders results.
module LawSpec.Component (componentRequest, VersionSelection (..), selectVersions) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as M
import Data.Aeson.Types (Pair)
import Data.Foldable (toList)
import qualified Data.Text as T
import LawSpec.Manifest.Decode (decodeJSONManifest)
import LawSpec.Service.Manifest (manifestProblems)
import LawSpec.Version (VersionSelection (..), selectVersions)

componentRequest :: Value -> Maybe Value
componentRequest (Object request)
  | Just (String method) <- M.lookup "method" request,
    method `elem` ["componentManifest", "packageVersions"] =
      Just $
        if M.lookup "schemaVersion" request /= Just (Number 5)
          then response ["component requests require schemaVersion 5"] []
          else case method of
            "componentManifest" ->
              let value = M.lookup "manifest" request
               in response
                    (manifestProblems (decodeJSONManifest value))
                    ["manifest" .= value]
            _ -> case (M.lookup "range" request, M.lookup "versions" request) of
              (Just (String range), Just (Array versions)) ->
                let VersionSelection problems chosen =
                      selectVersions
                        (T.unpack range)
                        [T.unpack text | String text <- toList versions]
                 in response problems (maybe [] (\selected -> ["versions" .= selected]) chosen)
              _ -> response ["packageVersions requires a range and versions array"] []
componentRequest _ = Nothing

response :: [String] -> [Pair] -> Value
response problems fields =
  object $
    [ "schemaVersion" .= (5 :: Int),
      "diagnostics"
        .= [object ["code" .= ("manifest" :: String), "message" .= problem, "at" .= Null] | problem <- problems]
    ]
      ++ fields
