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
data Artifact = Artifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String } deriving (Eq, Show, Generic)
instance ToJSON Location
instance ToJSON Diagnostic
instance ToJSON Artifact where
  toJSON Artifact{..} = object ["path" .= artifactPath, "content" .= artifactContent, "ownership" .= ownership, "placement" .= artifactPlacement]
instance FromJSON Source
instance ToJSON Source

data Span = Span { spanStart :: Location, spanEnd :: Location } deriving (Eq, Show, Generic)
instance ToJSON Span
pointSpan :: Location -> Span
pointSpan p = Span p p
