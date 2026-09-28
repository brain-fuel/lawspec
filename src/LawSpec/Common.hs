-- Shared protocol infrastructure: no syntax, inference or backend dependencies.
module LawSpec.Common where
import Data.Aeson
import GHC.Generics (Generic)

data Generation = Generation { cases :: Int, maxAttempts :: Int, maxShrinks :: Int, exhaustiveLimit :: Int } deriving (Eq, Show, Generic)
defaultGeneration :: Generation
defaultGeneration = Generation 100 10000 1000 4096
instance ToJSON Generation
instance FromJSON Generation where
  parseJSON = withObject "generation" $ \o -> Generation <$> o .:? "cases" .!= 100 <*> o .:? "maxAttempts" .!= 10000 <*> o .:? "maxShrinks" .!= 1000 <*> o .:? "exhaustiveLimit" .!= 4096
data Location = Location { file :: String, line :: Int, column :: Int } deriving (Eq, Show, Generic)
data Diagnostic = Diagnostic { code :: String, message :: String, at :: Maybe Location } deriving (Eq, Show, Generic)
data Source = Source { path :: String, content :: String } deriving (Eq, Show, Generic)
data Artifact
  = Artifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String }
  | AdapterArtifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String, canonicalAdapter :: String }
  deriving (Eq, Show, Generic)

-- Canonical generated scaffold, never the user's implementation. A layout-only
-- change must not be reported as a changed adapter requirement.
adapterReference :: Artifact -> Maybe String
adapterReference AdapterArtifact{canonicalAdapter=reference} = Just reference
adapterReference _ = Nothing

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

data Span = Span { spanStart :: Location, spanEnd :: Location } deriving (Eq, Show, Generic)
instance ToJSON Span
pointSpan :: Location -> Span
pointSpan p = Span p p
