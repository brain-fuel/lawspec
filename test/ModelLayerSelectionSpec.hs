-- | Optional model execution never removes the typed program or its APIs.
module ModelLayerSelectionSpec (test_modelLayerSelection) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.List (sortOn,isInfixOf)
import qualified Data.Vector as Vector
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Verification as V
import LawSpec.CoreEmit (emitPlanWithFormat,targets)
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Common (Artifact(..))
import LawSpec.Testing
import LawSpec.Api (dispatch)
import Test.Hspec

fixture="test/fixtures/canonical-model-layer-selection.lawspec"
checked bits source=either (fail.show) pure
  (compileCoreCanonical bits defaultGeneration [Source fixture source])
planned layers core=either (fail.show) pure (planTestingWith (V.Verification layers) core)
emitted compact target plan=either (fail.show) pure (emitPlanWithFormat compact target plan)
sources files=sortOn (\(path,_,_)->path)
  [(artifactPath a,artifactContent a,ownership a) | a<-files,artifactPlacement a=="source"]
field name (Object fields)=maybe Null id (KM.lookup name fields)
field _ _=Null
items (Array values)=Vector.toList values
items _=[]

-- ref:REQ-progressive-verification ref:DEC-total-definitions
test_modelLayerSelection=describe "independent native model layer selection" $ do
  it "retains complete typed models, supervisors and bridges when model execution is disabled" $ do
    source<-readFile fixture
    forM_ [32,64] $ \bits -> do
      core<-checked bits source
      disabled<-planned [] core
      enabled<-planned [V.Model] core
      planModelChecks disabled `shouldBe` False
      planModelChecks enabled `shouldBe` True
      map plannedUnit (plannedUnits disabled) `shouldBe` map plannedUnit (plannedUnits enabled)
      concatMap (C.unitMachines . plannedUnit) (plannedUnits disabled) `shouldNotBe` []
      concatMap (C.unitSupervisors . plannedUnit) (plannedUnits disabled) `shouldNotBe` []
      concatMap (C.unitDefinitions . plannedUnit) (plannedUnits disabled) `shouldNotBe` []
  it "preserves every native source and adapter API while omitting unselected model tests" $ do
    source<-readFile fixture
    forM_ [32,64] $ \bits -> do
      core<-checked bits source
      disabled<-planned [] core
      enabled<-planned [V.Model] core
      forM_ [False,True] $ \compact -> forM_ targets $ \target -> do
        off<-emitted compact target disabled
        on<-emitted compact target enabled
        sources off `shouldBe` sources on
        [(artifactPath a,artifactContent a) | a<-off,artifactPlacement a=="test"]
          `shouldNotBe` [(artifactPath a,artifactContent a) | a<-on,artifactPlacement a=="test"]
  it "preserves independently selected ordinary law tests beside the model APIs" $ do
    source<-readFile fixture
    core<-checked 64 source
    propertyOnly<-planned [V.Property,V.Examples] core
    allChecks<-planned [V.Property,V.Examples,V.Model] core
    concatMap plannedProperties (plannedUnits propertyOnly) `shouldBe`
      concatMap plannedProperties (plannedUnits allChecks)
    concatMap plannedProperties (plannedUnits propertyOnly) `shouldNotBe` []
    planModelChecks propertyOnly `shouldBe` False
    forM_ targets $ \target -> do
      off<-emitted False target propertyOnly
      on<-emitted False target allChecks
      sources off `shouldBe` sources on
  it "keeps mandatory definition errors in reference code outside the layer switch" $ do
    source<-readFile fixture
    let bad=source++"\nfunction invalidReference (n :: Integer) -> Integer is prelude.quot n 0 end function\n"
    compileCoreCanonical 64 defaultGeneration [Source fixture bad] `shouldSatisfy`
      either (any (isInfixOf "zero" . show)) (const False)
  it "returns no optional model manifest entries or verification claim when no layer is selected" $ do
    source<-readFile fixture
    forM_ targets $ \target -> do
      let request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
            "method" .= ("planGeneration"::String),"target" .= target,
            "verification" .= object ["layers" .= ([]::[String])],
            "sources" .= [object ["path" .= fixture,"content" .= source]]]
      response<-maybe (fail "invalid compiler JSON") pure (decode (dispatch (encode request)))
      items (field "diagnostics" response) `shouldBe` []
      items (field "files" response) `shouldNotBe` []
      items (field "tests" response) `shouldBe` []
      field "selection" (field "verification" response) `shouldBe` String "no-selected-checks"
      let optional=[e | e<-items (field "evidence" response),field "stage" e `elem`
            map String ["model","linearizable","restart","scenario","supervision"]]
      optional `shouldNotBe` []
      map (field "status") optional `shouldSatisfy` all (==String "not-verified")
  it "registers real model-only test slots on every target without planning ordinary laws" $ do
    source<-readFile fixture
    forM_ targets $ \target -> do
      let request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
            "method" .= ("planGeneration"::String),"target" .= target,
            "verification" .= object ["layers" .= (["model"]::[String])],
            "sources" .= [object ["path" .= fixture,"content" .= source]]]
      response<-maybe (fail "invalid compiler JSON") pure (decode (dispatch (encode request)))
      items (field "diagnostics" response) `shouldBe` []
      let entries=items (field "tests" response)
          files=map (field "path") (items (field "files" response))
      length entries `shouldBe` 5
      forM_ entries $ \entry -> do
        field "file" entry `shouldSatisfy` (`elem` files)
        show (field "law" entry) `shouldSatisfy`
          (\identity->"::model::account::" `isInfixOf` identity || "::supervision" `isInfixOf` identity)
      let optional=[e | e<-items (field "evidence" response),field "stage" e `elem`
            map String ["model","linearizable","restart","scenario","supervision"]]
      map (field "status") optional `shouldSatisfy` all (==String "planned")
  it "rejects colliding selected native model slots without rejecting unselected models" $ do
    source<-readFile fixture
    let neighbor=unlines ["actor account_parallel :: Account by Int64 is",
          "  start openAccount by 0", "  on deposit by modelDeposit", "end"]
    core<-checked 64 (source++"\n"++neighbor)
    disabled<-planned [] core
    enabled<-planned [V.Model] core
    emitPlanWithFormat False "python" disabled `shouldSatisfy` either (const False) (const True)
    emitPlanWithFormat False "python" enabled `shouldSatisfy`
      either (any (isInfixOf "native model checks share generated test names" . show)) (const False)
