-- | Schema-5 JSON adapter for shared manifest and version services. Admission
-- uses compiler-independent domain records before this adapter renders results.
module LawSpec.Component (componentRequest, VersionSelection (..), selectVersions) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as M
import Data.Aeson.Types (Pair)
import Data.Foldable (toList)
import qualified Data.Text as T
import LawSpec.ActorRuntime (defaultActorSettings)
import LawSpec.Manifest.Decode (decodeJSONManifest)
import LawSpec.ProjectName (NameSource (..), Project (..), resolveProject)
import LawSpec.Scaffold (scaffoldFilesForRelease)
import LawSpec.TargetOptions (defaultJavaRelease)
import LawSpec.Service.Manifest (manifestProblems)
import LawSpec.Version (VersionSelection (..), selectVersions)

componentRequest :: Value -> Maybe Value
componentRequest (Object request)
  | Just (String method) <- M.lookup "method" request,
    method `elem` ["componentManifest", "packageVersions", "scaffold"] =
      Just $
        if M.lookup "schemaVersion" request /= Just (Number 5)
          then response ["component requests require schemaVersion 5"] []
          else case method of
            "scaffold" -> scaffold request
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

-- | The build files lawspec init writes for a target, named for the project.
-- The host sends what it read (the options, the build files already in the
-- target's root, the manifest's name and the directory's) and writes what
-- comes back. ref:DEC-scaffold-project-name
scaffold :: Object -> Value
scaffold request = case (text "target", text "directory") of
  (Just target, Just directory) ->
    either (\problem -> responseOf "scaffold" [problem] []) id $ do
      project <-
        resolveProject target (text "name") (text "group") buildFiles (text "manifestName") directory
      files <- scaffoldFilesForRelease (projectBuildNames project) release defaultActorSettings False minify target
      Right $
        response
          []
          [ "files" .= [object ["path" .= path, "content" .= content] | (path, content) <- files],
            "project"
              .= object
                ( [ "name" .= projectName project,
                    "component" .= projectComponent project,
                    "summary" .= projectSummary project
                  ]
                    ++ case projectSource project of
                      FromOption -> ["source" .= ("option" :: String)]
                      FromBuildFile file -> ["source" .= ("build-file" :: String), "file" .= file]
                      FromManifest -> ["source" .= ("manifest" :: String)]
                      FromDirectory -> ["source" .= ("directory" :: String)]
                )
          ]
  _ -> responseOf "scaffold" ["scaffold requires a target and a directory name"] []
  where
    text key = case M.lookup key request of
      Just (String value) -> Just (T.unpack value)
      _ -> Nothing
    minify = M.lookup "minify" request == Just (Bool True)
    release = case M.lookup "release" request of
      Just (Number value) -> round value
      _ -> defaultJavaRelease
    buildFiles =
      [ (T.unpack path, T.unpack content)
        | Just (Array entries) <- [M.lookup "buildFiles" request],
          Object entry <- toList entries,
          Just (String path) <- [M.lookup "path" entry],
          Just (String content) <- [M.lookup "content" entry]
      ]

response :: [String] -> [Pair] -> Value
response = responseOf "manifest"

responseOf :: String -> [String] -> [Pair] -> Value
responseOf code problems fields =
  object $
    [ "schemaVersion" .= (5 :: Int),
      "diagnostics"
        .= [object ["code" .= code, "message" .= problem, "at" .= Null] | problem <- problems]
    ]
      ++ fields
