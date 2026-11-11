-- | Explicit JSON and restricted EDN projections into manifest admission types.
-- The private reader only shares format decoding; it is not a component protocol.
-- ref:DEC-haskell-application-port ref:REQ-compiler-api-contract
module LawSpec.Manifest.Decode (decodeJSONManifest, decodeEDNManifest, admitEDNManifest) where

import qualified Data.Aeson as JSON
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as M
import Data.Foldable (toList)
import Data.List (sortOn)
import qualified Data.Text as T
import LawSpec.Manifest.EDN
import LawSpec.Manifest.Types
import LawSpec.Service.Manifest (manifestProblems)

-- | Keep syntax failure distinct from a parsed manifest with admission errors.
-- The original EDN value remains available for lossless rendering.
admitEDNManifest :: String -> Either ManifestError (ManifestValue, [String])
admitEDNManifest input = do
  value <- parseManifest input
  pure (value, manifestProblems (decodeEDNManifest value))

decodeJSONManifest :: Maybe JSON.Value -> Field Manifest
decodeJSONManifest = maybe Absent (decodeManifest jsonReader)

decodeEDNManifest :: ManifestValue -> Field Manifest
decodeEDNManifest = decodeManifest ednReader

data Reader value = Reader
  { readObject :: value -> Maybe [(String, value)],
    readArray :: value -> Maybe [value],
    readString :: value -> Maybe String,
    readVersion :: value -> Maybe ManifestVersion,
    readNull :: value -> Bool
  }

jsonReader :: Reader JSON.Value
jsonReader = Reader object array string version (== JSON.Null)
  where
    object (JSON.Object values) = Just [(K.toString key, value) | (key, value) <- M.toList values]
    object _ = Nothing
    array (JSON.Array values) = Just (toList values)
    array _ = Nothing
    string (JSON.String value) = Just (T.unpack value)
    string _ = Nothing
    version (JSON.Number value) = Just (if value == 1 then ManifestVersion1 else UnsupportedManifestVersion)
    version _ = Nothing

ednReader :: Reader ManifestValue
ednReader = Reader object array string version (== ManifestNil)
  where
    object (ManifestMap values) = Just (sortOn fst values)
    object _ = Nothing
    array (ManifestVector values) = Just values
    array _ = Nothing
    string (ManifestString value) = Just value
    string _ = Nothing
    version (ManifestInteger value) = Just (if value == 1 then ManifestVersion1 else UnsupportedManifestVersion)
    version _ = Nothing

decodeManifest :: Reader value -> value -> Field Manifest
decodeManifest reader = object $ \fields ->
  Manifest
    (map fst fields)
    (field version "manifestVersion" fields)
    (field string "languageProfile" fields)
    (field identity "component" fields)
    (field identity "package" fields)
    (field strings "sources" fields)
    (field (array target) "targets" fields)
    (field (named dependency) "dependencies" fields)
    (field strings "packages" fields)
    (field strings "inputs" fields)
    (field strings "assets" fields)
    (field (array exception) "authoringExceptions" fields)
    (field (array contract) "provides" fields)
    (field (named contract) "requires" fields)
  where
    object build value = maybe Invalid (Present . build) (readObject reader value)
    array decode value = maybe Invalid (Present . map decode) (readArray reader value)
    named decode = object (map (\(key, value) -> (key, decode value)))
    string value = maybe Invalid Present (readString reader value)
    version value = maybe Invalid Present (readVersion reader value)
    strings = array string
    identity = object $ \fields -> Identity (map fst fields) (field string "name" fields) (field string "version" fields)
    target = object $ \fields -> Target (map fst fields) (field string "language" fields) (field string "root" fields) (field actors "actors" fields)
    actors value
      | readNull reader value = Present NoActors
      | otherwise = object (\fields -> Actors (map fst fields) (field string "runtime" fields) (field string "remote" fields)) value
    dependency value = case readString reader value of
      Just range -> Present (VersionRange range)
      Nothing -> object (SourceDependency . source) value
    source fields =
      Source
        (map fst fields)
        (field dependency "version" fields)
        (field string "path" fields)
        (field string "git" fields)
        (field string "rev" fields)
        (field string "tagPrefix" fields)
        (field string "subdir" fields)
        (field string "archive" fields)
        (field string "sha256" fields)
    exception = object $ \fields ->
      AuthoringException
        (map fst fields)
        (field string "declaration" fields)
        (field string "rule" fields)
        (field string "reason" fields)
    contract = object $ \fields ->
      Contract
        (map fst fields)
        (field string "contract" fields)
        (field strings "abilities" fields)
        (field strings "declarations" fields)
        (field strings "settings" fields)

field :: (value -> Field a) -> String -> [(String, value)] -> Field a
field decode name = maybe Absent decode . lookup name
