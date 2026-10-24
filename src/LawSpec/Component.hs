-- | Component metadata and package version selection share the native/WASM
-- core. Hosts read EDN as data; this module checks its toolchain meaning.
module LawSpec.Component (componentRequest) where

import Data.Aeson
import Data.Aeson.Types (Pair)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as M
import Data.Char (isAlphaNum)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Ord (Down(..))
import qualified Data.Text as T
import LawSpec.Packages (parseVersion, parseRange, satisfies)
import LawSpec.Targets (targets)

componentRequest :: Value -> Maybe Value
componentRequest (Object request)
  | Just (String method) <- M.lookup "method" request
  , method `elem` ["componentManifest", "packageVersions"] = Just $
      if M.lookup "schemaVersion" request /= Just (Number 5)
      then response ["component requests require schemaVersion 5"] []
      else case method of
        "componentManifest" ->
          let value = M.lookup "manifest" request
           in response (maybe ["manifest is required"] manifestProblems value)
                ["manifest" .= value]
        _ -> case (M.lookup "range" request, M.lookup "versions" request) of
          (Just (String range), Just (Array versions)) ->
            case parseRange (T.unpack range) of
              Left problem -> response [problem] []
              Right constraint ->
                let parsed = [(text, parseVersion (T.unpack text)) | String text <- toList versions]
                    problems = [problem | (_, Left problem) <- parsed]
                    chosen = [text | (text, Right version) <- sortOn (fmap Down . snd) parsed, satisfies constraint version]
                 in response problems ["versions" .= chosen]
          _ -> response ["packageVersions requires a range and versions array"] []
componentRequest _ = Nothing

response :: [String] -> [Pair] -> Value
response problems fields = object $
  ["schemaVersion" .= (5 :: Int), "diagnostics" .=
    [object ["code" .= ("manifest" :: String), "message" .= problem, "at" .= Null] | problem <- problems]] ++ fields

manifestProblems :: Value -> [String]
manifestProblems (Object manifest) = concat
  [ unknown "manifest" allowed manifest
  , ["manifestVersion must be 1" | M.lookup "manifestVersion" manifest /= Just (Number 1)]
  , ["languageProfile must be 1.0-rc.2" | M.lookup "languageProfile" manifest /= Just (String "1.0-rc.2")]
  , ["a component or package identity is required" | not (any (`M.member` manifest) ["component", "package"])]
  , concat [maybe [] (identity (K.toString name)) (M.lookup name manifest) | name <- ["component", "package"]]
  , case M.lookup "sources" manifest of
      Just (Array values) -> strings "sources" values
      _ -> ["sources must be an array of paths"]
  , case M.lookup "targets" manifest of
      Nothing -> []
      Just (Array values) -> concat [target index value | (index, value) <- zip [0 :: Int ..] (toList values)]
      _ -> ["targets must be an array"]
  , case M.lookup "dependencies" manifest of
      Nothing -> []
      Just (Object values) -> concat [dependency (K.toString key) value | (key, value) <- M.toList values]
      _ -> ["dependencies must be a map"]
  , concat [case M.lookup name manifest of
      Nothing -> []
      Just (Array values) -> strings (K.toString name) values
      _ -> [K.toString name ++ " must be an array of paths"] | name <- ["packages", "inputs", "assets"]]
  , case M.lookup "provides" manifest of
      Nothing -> []
      Just (Array values) -> concat [contract "provides" value | value <- toList values]
      _ -> ["provides must be an array"]
  , case M.lookup "requires" manifest of
      Nothing -> []
      Just (Object values) -> concat [contract ("requires." ++ K.toString key) value | (key,value) <- M.toList values]
      _ -> ["requires must be a map of named requirements"]
  ]
  where
    allowed = ["manifestVersion", "component", "package", "languageProfile", "sources", "targets", "dependencies", "packages",
      "verification", "generation", "machineBits", "cache", "attestation", "description", "inputs", "assets", "provides", "requires"]
manifestProblems _ = ["manifest must be a map"]

unknown :: String -> [K.Key] -> Object -> [String]
unknown at allowed object' = [at ++ ": unknown field " ++ K.toString key | key <- M.keys object', key `notElem` allowed]

identity :: String -> Value -> [String]
identity at (Object value) = unknown at ["name", "version"] value ++
  [at ++ ".name must be a nonempty portable name" | case M.lookup "name" value of
    Just (String name) -> T.null name || not (T.all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) name)
    _ -> True] ++
  case M.lookup "version" value of
    Just (String version) -> either (\problem -> [at ++ ".version: " ++ problem]) (const []) (parseVersion (T.unpack version))
    _ -> [at ++ ".version must be an exact semantic version"]
identity at _ = [at ++ " must be an identity map"]

strings :: String -> Array -> [String]
strings at values = [at ++ " must contain nonempty strings" | any invalid (toList values)]
  where invalid (String value) = T.null value
        invalid _ = True

target :: Int -> Value -> [String]
target index (Object value) = unknown at
  ["name", "language", "root", "sourceDir", "testDir", "python", "maven", "gradle", "rustc", "cargo", "nativeBindings"] value ++
  [at ++ ".language is unsupported" | M.lookup "language" value `notElem` map (Just . String . T.pack) targets] ++
  [at ++ ".root must be a nonempty path" | case M.lookup "root" value of Just (String root) -> T.null root; _ -> True]
  where at = "targets[" ++ show index ++ "]"
target index _ = ["targets[" ++ show index ++ "] must be a map"]

dependency :: String -> Value -> [String]
dependency name (String range) = either (\problem -> [name ++ ": " ++ problem]) (const []) (parseRange (T.unpack range))
dependency name (Object value) = unknown ("dependencies." ++ name)
  ["version", "path", "git", "rev", "tagPrefix", "subdir", "archive", "sha256"] value ++
  dependency name (maybe Null id (M.lookup "version" value)) ++
  [name ++ ": give exactly one of path, git or archive" | length (filter (`M.member` value) ["path", "git", "archive"]) /= 1] ++
  [name ++ ": an archive requires a SHA-256 digest" | M.member "archive" value, case M.lookup "sha256" value of
    Just (String digest) -> T.length digest /= 64 || not (T.all (`elem` ("0123456789abcdef" :: String)) digest)
    _ -> True]
dependency name _ = [name ++ ": dependency must give a version range or source map"]

contract :: String -> Value -> [String]
contract at (Object value) = unknown at ["contract", "abilities", "declarations", "settings"] value ++
  [at ++ ".contract must name a resolved package" | case M.lookup "contract" value of Just (String name) -> T.null name; _ -> True] ++
  concat [case M.lookup field value of
    Nothing -> []
    Just (Array values) -> strings (at ++ "." ++ K.toString field) values
    _ -> [at ++ "." ++ K.toString field ++ " must be an array"] | field <- ["abilities", "declarations", "settings"]]
contract at _ = [at ++ " must be a contract map"]
