-- | Shared protocol infrastructure: no syntax, inference or backend dependencies.
module LawSpec.Common where
import Data.Aeson
import GHC.Generics (Generic)

-- | One set of generation limits for every target, mapped onto each framework's
-- own settings, so a law is tried as hard on one target as on another.
-- ref:DEC-native-property-frameworks
data Generation = Generation { cases :: Int, maxAttempts :: Int, maxShrinks :: Int, exhaustiveLimit :: Int } deriving (Eq, Show, Generic)
-- | A hundred cases is the common default of the property frameworks LawSpec
-- targets; the exhaustive limit lets small domains be checked completely.
-- ref:quickcheck
defaultGeneration :: Generation
defaultGeneration = Generation 100 10000 1000 4096
instance ToJSON Generation
instance FromJSON Generation where
  parseJSON = withObject "generation" $ \o -> Generation <$> o .:? "cases" .!= 100 <*> o .:? "maxAttempts" .!= 10000 <*> o .:? "maxShrinks" .!= 1000 <*> o .:? "exhaustiveLimit" .!= 4096
-- | Diagnostics point at a file, line and column, which every editor can follow.
data Location = Location { file :: String, line :: Int, column :: Int } deriving (Eq, Show, Generic)
-- | Every failure carries a stable code as well as a message, so tools and tests
-- can match a kind of error without parsing its wording.
data Diagnostic = Diagnostic { code :: String, message :: String, at :: Maybe Location } deriving (Eq, Show, Generic)
-- | The compiler reads no files itself: hosts pass sources in, so the WASM build
-- and the native build behave alike. ref:DEC-wasm-distribution
data Source = Source { path :: String, content :: String } deriving (Eq, Show, Generic)
-- | Each output says who owns it: generated files are rewritten freely, adapter
-- files belong to the user and are never overwritten. ref:DEC-adapter-ownership
data Artifact
  = Artifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String }
  | AdapterArtifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String, canonicalAdapter :: String }
  deriving (Eq, Show, Generic)

-- | Canonical generated scaffold, never the user's implementation. A layout-only
-- change must not be reported as a changed adapter requirement.
adapterReference :: Artifact -> Maybe String
adapterReference AdapterArtifact{canonicalAdapter=reference} = Just reference
adapterReference _ = Nothing

-- | A rewrite of generated text, such as escaping names, must reach the
-- canonical adapter too, or regeneration would see a difference that is not
-- there.
mapArtifactContent :: (String -> String) -> Artifact -> Artifact
mapArtifactContent f artifact = case artifact of
  AdapterArtifact{} -> artifact { artifactContent = f (artifactContent artifact), canonicalAdapter = f (canonicalAdapter artifact) }
  Artifact{} -> artifact { artifactContent = f (artifactContent artifact) }
instance ToJSON Location
instance ToJSON Diagnostic
instance ToJSON Artifact where
  toJSON artifact = object
    (["path" .= artifactPath artifact, "content" .= artifactContent artifact,
      "ownership" .= ownership artifact, "placement" .= artifactPlacement artifact] ++
     maybe [] (\reference -> ["adapterReference" .= reference]) (adapterReference artifact))
instance FromJSON Source
instance ToJSON Source

-- | Core keeps the span of each expression, so a failing law points at the
-- exact text.
data Span = Span { spanStart :: Location, spanEnd :: Location } deriving (Eq, Show, Generic)
instance ToJSON Span
-- | Where only a position is known, it is a span of no width.
pointSpan :: Location -> Span
pointSpan p = Span p p
