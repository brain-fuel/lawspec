-- | Optional law verification. Intrinsic definition validation and its deferred
-- runtime contracts are deliberately outside this selection.
module LawSpec.Core.Verification
  ( Verification(..), Layer(..), noVerification, legacyVerification, selected
  , layerName, executableLayers
  ) where

import Data.Aeson
import Control.Monad (unless)
import Data.List (nub)

data Layer = Proof | Exhaustive | Property | Examples | Runtime | Model | Analysis
  deriving (Eq, Ord, Show, Enum, Bounded)
newtype Verification = Verification { verificationLayers :: [Layer] }
  deriving (Eq, Show)
noVerification :: Verification
noVerification = Verification []
legacyVerification :: Verification
legacyVerification = Verification [Proof, Exhaustive, Property, Examples, Runtime, Model, Analysis]
selected :: Verification -> Layer -> Bool
selected (Verification layers) layer = layer `elem` layers
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
  toJSON (Verification layers) = object ["layers" .= layers]
instance FromJSON Verification where
  parseJSON = withObject "verification" $ \o -> do
    layers <- o .:? "layers" .!= []
    unless (length layers == length (nub layers)) (fail "verification.layers contains a duplicate layer")
    pure (Verification layers)
