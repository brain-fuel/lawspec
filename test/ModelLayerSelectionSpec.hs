-- | Optional model execution never removes the typed program or its APIs.
module ModelLayerSelectionSpec (test_modelLayerSelection) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.List (sortOn,isInfixOf)
import qualified Data.Vector as Vector
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Verification as V
import qualified LawSpec.Core.Evidence as E
import LawSpec.Core.Machine (Machine(..), Command(..))
import qualified LawSpec.BeamModelChecks as B
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
  it "links every native model slot to the existing typed obligations without claiming session safety" $ do
    source<-readFile fixture
    let extra=unlines ["", "scenario `receipt: 100% matched` in account is",
          "  value <- deposit 1", "  expect value = 1", "end"]
    forM_ targets $ \target -> do
      let request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
            "method" .= ("planGeneration"::String),"target" .= target,
            "verification" .= object ["layers" .= (["model"]::[String])],
            "sources" .= [object ["path" .= fixture,"content" .= (source++extra)]]]
      response<-maybe (fail "invalid compiler JSON") pure (decode (dispatch (encode request)))
      items (field "diagnostics" response) `shouldBe` []
      let entries=items (field "tests" response)
          links=concatMap (items . field "obligations") entries
          evidence=items (field "evidence" response)
      length entries `shouldBe` 6
      length links `shouldBe` 7
      forM_ links $ \link -> do
        any (\item -> field "declaration" item==field "declaration" link &&
          field "stage" item==field "stage" link) evidence `shouldBe` True
        field "stage" link `shouldSatisfy` (`notElem` map String ["race-free","deadlock-free"])
      let escaped=[entry | entry<-entries,"receipt%3A 100%25 matched" `isInfixOf` show (field "law" entry)]
      length escaped `shouldBe` 1
      field "declaration" (head (items (field "obligations" (head escaped)))) `shouldBe`
        String "example.actors::model::account::scenario::receipt: 100% matched"
  it "plans no phantom law tests for an examples-only selection without examples" $ do
    source<-readFile fixture
    forM_ targets $ \target -> forM_ [["examples"],["examples","model"]] $ \layers -> do
      let request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
            "method" .= ("planGeneration"::String),"target" .= target,
            "verification" .= object ["layers" .= (layers::[String])],
            "sources" .= [object ["path" .= fixture,"content" .= source]]]
      response<-maybe (fail "invalid compiler JSON") pure (decode (dispatch (encode request)))
      items (field "diagnostics" response) `shouldBe` []
      length (items (field "tests" response)) `shouldBe` if "model" `elem` layers then 5 else 0
      [field "status" item | item<-items (field "evidence" response),field "stage" item==String "law"]
        `shouldSatisfy` all (==String "not-verified")
  it "keeps scoped search visible after quantifiers lower into native Boolean terms" $ do
    let source=unlines ["unit searchCoverage", "probe :: Bool -> Bool",
          "law finds is definition: for all (input :: Bool) =>",
          "  there exists (witness :: Bool) such that probe witness must be input end",
          "end end end"]
        request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
          "method" .= ("planGeneration"::String),"target" .= ("javascript"::String),
          "verification" .= object ["layers" .= (["exhaustive"]::[String])],
          "sources" .= [object ["path" .= ("search.lawspec"::String),"content" .= source]]]
    response<-maybe (fail "invalid compiler JSON") pure (decode (dispatch (encode request)))
    items (field "diagnostics" response) `shouldBe` []
    let [entry]=items (field "tests" response)
    field "kind" (field "coverage" entry) `shouldBe` String "finite-inputs"
    field "cases" (field "coverage" entry) `shouldBe` Number 2
    field "scopedQuantifiers" (field "coverage" entry) `shouldBe` Bool True
  it "does not credit a model run with restart checks when no restart command is declared" $ do
    source<-readFile fixture
    core<-checked 64 source
    let [unit]=[unit | unit<-C.programUnits core,not (null (C.unitMachines unit))]
        [machine]=C.unitMachines unit
        withoutRestart=machine{machineCommands=filter (not . commandRestart) (machineCommands machine)}
        check=B.Check (C.Id "sequential") "sequential" "sequential" (B.Sequential "account" withoutRestart)
    any commandRestart (machineCommands machine) `shouldBe` True
    map E.obligationStage (B.checkObligations unit check) `shouldBe` ["model"]
