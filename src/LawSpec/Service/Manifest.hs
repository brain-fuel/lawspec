-- | Pure manifest admission shared by external codecs and application components.
-- Keep diagnostic ordering and presence rules independent of transport adapters.
-- ref:DEC-haskell-application-port ref:REQ-compiler-api-contract
module LawSpec.Service.Manifest (manifestProblems) where

import Data.Char (isAlphaNum)
import qualified Data.Text as T
import LawSpec.ActorRuntime (actorFields)
import LawSpec.Manifest.Types
import LawSpec.Targets (targets)
import LawSpec.Version (parseRange, parseVersion)

manifestProblems :: Field Manifest -> [String]
manifestProblems Absent = ["manifest is required"]
manifestProblems Invalid = ["manifest must be a map"]
manifestProblems (Present manifest) =
  concat
    [ unknown "manifest" allowed (manifestKeys manifest),
      ["manifestVersion must be 1" | manifestVersion manifest /= Present ManifestVersion1],
      ["languageProfile must be 1.0-rc.2" | languageProfile manifest /= Present "1.0-rc.2"],
      ["a component or package identity is required" | not (present (componentIdentity manifest) || present (packageIdentity manifest))],
      optional (identity "component") (componentIdentity manifest),
      optional (identity "package") (packageIdentity manifest),
      case sources manifest of
        Present values -> strings "sources" values
        _ -> ["sources must be an array of paths"],
      optional (array "targets must be an array" (\values -> concat [target index value | (index, value) <- zip [0 :: Int ..] values])) (manifestTargets manifest),
      optional (array "dependencies must be a map" (concatMap (uncurry dependency))) (dependencies manifest),
      concat [optional (array (name ++ " must be an array of paths") (strings name)) value | (name, value) <- [("packages", packages manifest), ("inputs", inputs manifest), ("assets", assets manifest)]],
      optional (array "authoringExceptions must be an array" (concatMap authoringException)) (authoringExceptions manifest),
      optional (array "provides must be an array" (concatMap (contract "provides"))) (provides manifest),
      optional (array "requires must be a map of named requirements" (concatMap (\(name, value) -> contract ("requires." ++ name) value))) (requires manifest)
    ]
  where
    allowed = ["manifestVersion", "component", "package", "languageProfile", "sources", "targets", "dependencies", "packages", "authoringExceptions", "verification", "generation", "machineBits", "cache", "cacheDirectory", "attestation", "description", "inputs", "assets", "provides", "requires"]

unknown :: String -> [String] -> [String] -> [String]
unknown at allowed keys = [at ++ ": unknown field " ++ key | key <- keys, key `notElem` allowed]

present :: Field a -> Bool
present Absent = False
present _ = True

optional :: (Field a -> [String]) -> Field a -> [String]
optional _ Absent = []
optional check value = check value

array :: String -> (a -> [String]) -> Field a -> [String]
array _ check (Present value) = check value
array problem _ _ = [problem]

nonempty :: Field String -> Bool
nonempty (Present value) = not (null value)
nonempty _ = False

identity :: String -> Field Identity -> [String]
identity at (Present value) =
  unknown at ["name", "version"] (identityKeys value)
    ++ [at ++ ".name must be a nonempty portable name" | case identityName value of Present name -> null name || not (all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) name); _ -> True]
    ++ case identityVersion value of
      Present version -> either (\problem -> [at ++ ".version: " ++ problem]) (const []) (parseVersion version)
      _ -> [at ++ ".version must be an exact semantic version"]
identity at _ = [at ++ " must be an identity map"]

strings :: String -> [Field String] -> [String]
strings at values = [at ++ " must contain nonempty strings" | any (not . nonempty) values]

target :: Int -> Field Target -> [String]
target index (Present value) =
  unknown at ["name", "language", "root", "sourceDir", "testDir", "generatedSourceDir", "generatedTestDir", "release", "python", "maven", "gradle", "rustc", "cargo", "scala", "swift", "clojure", "dotnet", "nativeBindings", "actors"] (targetKeys value)
    ++ [at ++ ".language is unsupported" | targetLanguage value `notElem` map Present targets]
    ++ [at ++ ".root must be a nonempty path" | not (nonempty (targetRoot value))]
    ++ actors (targetActors value)
  where
    language = case targetLanguage value of
      Present name -> Just name
      _ -> Nothing
    actors (Present (Actors keys runtime remote)) = either id (const []) (actorFields (at ++ ".actors") language keys (field runtime) (field remote))
    actors Invalid = [at ++ ".actors must be a map, such as {:runtime :pekko}"]
    actors _ = []
    field (Present text) = Just (Just text)
    field Invalid = Just Nothing
    field Absent = Nothing
    at = "targets[" ++ show index ++ "]"
target index _ = ["targets[" ++ show index ++ "] must be a map"]

dependency :: String -> Field Dependency -> [String]
dependency name (Present (VersionRange range)) = either (\problem -> [name ++ ": " ++ problem]) (const []) (parseRange range)
dependency name (Present (SourceDependency value)) =
  unknown ("dependencies." ++ name) ["version", "path", "git", "rev", "tagPrefix", "subdir", "archive", "sha256"] (sourceKeys value)
    ++ dependency name (sourceVersion value)
    ++ [name ++ ": give exactly one of path, git or archive" | length (filter present [sourcePath value, sourceGit value, sourceArchive value]) /= 1]
    ++ [name ++ "." ++ field ++ " must be a nonempty string" | (field, entry) <- [("path", sourcePath value), ("git", sourceGit value), ("rev", sourceRevision value), ("subdir", sourceSubdirectory value), ("archive", sourceArchive value)], present entry, not (nonempty entry)]
    ++ [name ++ ".tagPrefix must be a string" | sourceTagPrefix value == Invalid]
    ++ [name ++ "." ++ field ++ " applies only to a Git dependency" | (field, entry) <- [("rev", sourceRevision value), ("tagPrefix", sourceTagPrefix value), ("subdir", sourceSubdirectory value)], present entry, not (present (sourceGit value))]
    ++ [name ++ ": an archive requires a SHA-256 digest" | present (sourceArchive value), case sourceDigest value of Present digest -> length digest /= 64 || not (all (`elem` ("0123456789abcdef" :: String)) digest); _ -> True]
dependency name _ = [name ++ ": dependency must give a version range or source map"]

authoringException :: Field AuthoringException -> [String]
authoringException (Present value) =
  unknown "authoring exception" ["declaration", "rule", "reason"] (exceptionKeys value)
    ++ ["authoring exception requires nonempty " ++ field | (field, entry) <- [("declaration", exceptionDeclaration value), ("rule", exceptionRule value), ("reason", exceptionReason value)], case entry of Present text -> T.null (T.strip (T.pack text)); _ -> True]
authoringException _ = ["authoring exception must be a map"]

contract :: String -> Field Contract -> [String]
contract at (Present value) =
  unknown at ["contract", "abilities", "declarations", "settings"] (contractKeys value)
    ++ [at ++ ".contract must name a resolved package" | not (nonempty (contractName value))]
    ++ concat [optional (array (at ++ "." ++ field ++ " must be an array") (strings (at ++ "." ++ field))) entry | (field, entry) <- [("abilities", contractAbilities value), ("declarations", contractDeclarations value), ("settings", contractSettings value)]]
contract at _ = [at ++ " must be a contract map"]
