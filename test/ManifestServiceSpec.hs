-- | Frozen admission and selection outputs from before the typed service split.
-- Includes malformed requests and direct EDN admission without a JSON round trip.
-- ref:DEC-haskell-application-port ref:REQ-compiler-api-contract
module ManifestServiceSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as M
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Component (componentRequest)
import LawSpec.Manifest.Decode (admitEDNManifest)
import LawSpec.Manifest.EDN (ManifestError (..))
import Test.Hspec

data Fixture = Fixture String Value (Maybe Value) (Maybe String)

instance FromJSON Fixture where
  parseJSON = withObject "manifest service fixture" $ \fields ->
    Fixture <$> fields .: "name" <*> fields .: "request" <*> fields .: "response" <*> fields .:? "edn"

spec :: Spec
spec = describe "manifest service reference compatibility" $ do
  fixtures <- runIO $ do
    bytes <- B.readFile "test/fixtures/application-port/manifest-service.json"
    either fail pure (eitherDecode bytes >>= parseEither (withObject "reference" (.: "cases")) :: Either String [Fixture])
  forM_ fixtures $ \(Fixture name request expected edn) -> do
    it (name ++ " JSON request") $ componentRequest request `shouldBe` expected
    forM_ edn $ \input -> it (name ++ " direct EDN admission") $ do
      expectedProblems <- either fail pure (parseEither messages expected)
      case admitEDNManifest input of
        Left problem -> expectationFailure (show problem)
        Right (_, problems) -> problems `shouldBe` expectedProblems
  it "keeps EDN syntax rejection separate from admission diagnostics" $ do
    admitEDNManifest "{:sources [}" `shouldBe` Left (ManifestError "Expected exactly one complete EDN map")
    case admitEDNManifest "{}" of
      Left problem -> expectationFailure (show problem)
      Right (_, problems) -> length problems `shouldBe` 4
  where
    messages (Just (Object response)) = case M.lookup "diagnostics" response of
      Just value -> parseJSON value >>= mapM (withObject "diagnostic" (.: "message"))
      Nothing -> fail "reference has no diagnostics"
    messages _ = fail "reference has no response"
