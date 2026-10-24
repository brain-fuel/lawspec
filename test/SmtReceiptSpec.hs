-- | A proof receipt is bound to what a law does. Every task the corpus in
-- test/fixtures/smt-corpus makes keeps its lawFingerprint when the source
-- moves (every span changes), and a small program keeps it under a local
-- rename and a description edit but not under a behaviour edit. The tasks
-- come through the API's proofTasks method, as `lawspec prove` gets them.
-- ref:DEC-smt-semantic-receipts
module SmtReceiptSpec (test_receiptsFollowBehaviourNotSpelling) where

import Control.Monad (forM)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Foldable (toList)
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec
import qualified LawSpec.Api as API

corpus :: FilePath
corpus = "test/fixtures/smt-corpus"

-- | Each task's declaration, status and law fingerprint.
fingerprints :: String -> Integer -> String -> IO [(Text, Value, Maybe Value)]
fingerprints name bits content = do
  let request = object
        [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String)
        , "method" .= ("proofTasks" :: String), "machineBits" .= bits
        , "verification" .= object ["layers" .= ["proof" :: String]]
        , "sources" .= [object ["path" .= name, "content" .= content]] ]
  response <- maybe (fail ("no API response for " ++ name)) pure
    (decode (API.dispatch (encode request)) :: Maybe Value)
  rows <- case response of
    Object result | Just (Array tasks) <- K.lookup "proofTasks" result -> pure (toList tasks)
    _ -> fail ("no proof tasks for " ++ name ++ ": " ++ BL.unpack (encode response))
  forM rows $ \row -> case row of
    Object task | Just (String law) <- K.lookup "declaration" task, Just status <- K.lookup "status" task ->
      pure (law, status, K.lookup "lawFingerprint" task)
    _ -> fail ("malformed proof task in " ++ name)

small :: String -> String -> String -> String
small local description bound = unlines
  [ "unit receipts.example", ""
  , "function bump (" ++ local ++ " :: Int32 where " ++ local ++ " < 100) -> Int64 is " ++ local ++ " + 1 end function", ""
  , "law \"|bumping grows| is"
  , "  description: \"" ++ description ++ "\" end description"
  , "  definition : for all (n :: Int32 where n < 100) => bump n > " ++ bound ++ " end for all end definition"
  , "end law", "", "end unit" ]

test_receiptsFollowBehaviourNotSpelling :: Spec
test_receiptsFollowBehaviourNotSpelling = describe "proof receipts" $ do
  it "keep every corpus task's law fingerprint when the source moves" $ do
    names <- sort . filter (".lawspec" `isSuffixOf`) <$> listDirectory corpus
    results <- concat <$> sequence
      [ do content <- readFile (corpus </> name)
           before <- fingerprints name bits content
           after <- fingerprints name bits ("-- moved down a line\n\n" ++ content)
           pure [(name, bits, b, a) | (b, a) <- zip before after]
      | name <- names, bits <- [32, 64] ]
    length [() | (_, _, (_, String "ready", _), _) <- results] `shouldSatisfy` (> 0)
    [ (name, bits, law) | (name, bits, b@(law, _, _), a) <- results, b /= a ] `shouldBe` []
  it "keep a law's fingerprint under a local rename and a description edit" $ do
    before <- fingerprints "small.lawspec" 64 (small "x" "Bumping adds one." "n")
    renamed <- fingerprints "small.lawspec" 64 (small "value" "Bumping adds one." "n")
    reworded <- fingerprints "small.lawspec" 64 (small "x" "Bumping adds exactly one." "n")
    [s | (_, s, _) <- before] `shouldBe` [String "ready"]
    renamed `shouldBe` before
    reworded `shouldBe` before
  it "change a law's fingerprint when its behaviour changes" $ do
    before <- fingerprints "small.lawspec" 64 (small "x" "Bumping adds one." "n")
    changed <- fingerprints "small.lawspec" 64 (small "x" "Bumping adds one." "n - 1")
    map (\(_, _, f) -> f) changed `shouldNotBe` map (\(_, _, f) -> f) before
