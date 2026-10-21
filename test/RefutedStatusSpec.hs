-- | A law a confirmed counterexample shows false reports refuted, and the
-- build still fails: the compiler's exhaustive check keeps the law's row
-- with status refuted beside a refuted diagnostic.
module RefutedStatusSpec (test_refutedLawsAreReportedAndFail) where

import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Api as API
import qualified LawSpec.Core.Verification as V
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..), statusName)
import LawSpec.Discharge (dischargeEvidence, dischargeReporting, refutations)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

source :: String
source = unlines
  [ "unit refuted.laws\n"
  , "law \"|small numbers are below ten| is"
  , "  definition: for all (n :: Int8 where n >= 0 and n <= 20) => n < 10 end for all end definition"
  , "end law\n"
  , "law \"|small numbers are below thirty| is"
  , "  definition: for all (n :: Int8 where n >= 0 and n <= 20) => n < 30 end for all end definition"
  , "end law\n"
  , "end unit" ]

test_refutedLawsAreReportedAndFail :: Spec
test_refutedLawsAreReportedAndFail = describe "refuted laws" $ do
  it "names the status refuted" $ statusName Refuted `shouldBe` "refuted"
  it "keeps a refuted row beside the others, and its diagnostics fail the build" $ do
    program <- either (fail . show) pure (compileCore 64 defaultGeneration [Source "refuted.lawspec" source])
    evidence <- either (fail . show) pure (dischargeReporting (Just (V.Verification [V.Exhaustive])) program)
    let laws = [(obligationDeclaration o, obligationStatus o) | o <- evidence, obligationStage o == "law"]
    map snd laws `shouldMatchList` [Refuted, ExhaustivelyChecked]
    let failing = refutations program evidence
    failing `shouldSatisfy` (not . null)
    failing `shouldSatisfy` all ((== "refuted") . code)
    failing `shouldSatisfy` any (("is false for n = 10" `isInfixOf`) . message)
    dischargeEvidence program `shouldSatisfy` either (any ((== "refuted") . code)) (const False)
  it "reports the refuted row in the API response together with its diagnostics" $ do
    let request = object
          [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("check" :: String)
          , "verification" .= object ["layers" .= ["exhaustive" :: String]]
          , "sources" .= [object ["path" .= ("refuted.lawspec" :: String), "content" .= source]] ]
    Just (Object response) <- pure (decode (API.dispatch (encode request)) :: Maybe Value)
    Just (Array diagnostics) <- pure (K.lookup "diagnostics" response)
    [d | Object d <- toList diagnostics, K.lookup "code" d == Just (String "refuted")] `shouldSatisfy` (not . null)
    Just (Array rows) <- pure (K.lookup "evidence" response)
    [K.lookup "status" row | Object row <- toList rows, K.lookup "stage" row == Just (String "law")]
      `shouldMatchList` [Just (String "refuted"), Just (String "exhaustively-checked")]
