-- | Optional law verification. Intrinsic definition validation and its deferred
-- runtime contracts are deliberately outside this selection.
module LawSpec.Core.Verification
  ( Verification(..), Evaluation(..), evaluation, defaultEvaluation, withLayers, Layer(..), noVerification, selected
  , layerName, executableLayers
  ) where

import Data.Aeson
import Control.Monad (unless)
import Data.List (nub)

data Layer = Proof | Exhaustive | Property | Examples | Runtime | Model | Analysis
  deriving (Eq, Ord, Show, Enum, Bounded)
data Verification = Verification { verificationLayers :: [Layer] }
  | VerificationEvaluation { verificationLayers :: [Layer], verificationEvaluation :: Evaluation }
  deriving (Eq, Show)
data Evaluation = Evaluation { maxSteps :: Integer, deferLaws :: [String] }
  deriving (Eq, Show)
defaultEvaluation :: Evaluation
defaultEvaluation = Evaluation 1000000 []
evaluation :: Verification -> Evaluation
evaluation (Verification _) = defaultEvaluation
evaluation (VerificationEvaluation _ settings) = settings
withLayers :: [Layer] -> Verification -> Verification
withLayers layers config = config { verificationLayers = layers }
noVerification :: Verification
noVerification = Verification []
selected :: Verification -> Layer -> Bool
selected config layer = layer `elem` verificationLayers config
layerName :: Layer -> String
layerName = \case
  Proof -> "proof"
  Exhaustive -> "exhaustive"
  Property -> "property"
  Examples -> "examples"
  Runtime -> "runtime"
  Model -> "model"
  Analysis -> "analysis"
executableLayers :: Verification -> Bool
executableLayers config = any (selected config) [Exhaustive, Property, Examples, Model]
instance ToJSON Layer where toJSON = toJSON . layerName
instance FromJSON Layer where
  parseJSON = withText "verification layer" $ \name -> case [layer | layer <- [minBound..maxBound], toJSON layer == String name] of
    [layer] -> pure layer
    _ -> fail "verification.layers accepts proof, exhaustive, property, examples, runtime, model and analysis"
instance ToJSON Verification where
  toJSON config = object ["layers" .= verificationLayers config, "evaluation" .= evaluation config]
instance ToJSON Evaluation where
  toJSON (Evaluation steps deferred) = object ["maxSteps" .= steps, "deferLaws" .= deferred]
instance FromJSON Evaluation where
  parseJSON = withObject "verification.evaluation" $ \o -> do
    steps <- o .:? "maxSteps" .!= 1000000
    deferred <- o .:? "deferLaws" .!= []
    unless (steps > 0) (fail "verification.evaluation.maxSteps must be a positive integer")
    unless (length deferred == length (nub deferred)) (fail "verification.evaluation.deferLaws contains a duplicate law")
    pure (Evaluation steps deferred)
instance FromJSON Verification where
  parseJSON = withObject "verification" $ \o -> do
    layers <- o .:? "layers" .!= []
    unless (length layers == length (nub layers)) (fail "verification.layers contains a duplicate layer")
    settings <- o .:? "evaluation"
    pure (maybe (Verification layers) (VerificationEvaluation layers) settings)
