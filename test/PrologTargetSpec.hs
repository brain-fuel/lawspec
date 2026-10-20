-- | Admission and metadata boundaries of the public Prolog emitter.
-- End-to-end PLUnit controls run independently.
-- ref:DEC-prolog-janus
module PrologTargetSpec (test_prologEmitter) where

import Data.Either (isLeft, isRight)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Core as C
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (Plan(..), PlannedUnit(..), planTesting)
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Prolog.Emit (prologFromPython)
import LawSpec.Scalar (Scalar(..), textScalar)
import LawSpec.Witness (witnessPlan)
import LawSpec.Api (dispatch)

public :: [Value] -> String -> Value
public bindings source = case decode (dispatch (encode (object
  ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
   "method" .= ("planGeneration" :: String), "target" .= ("prolog" :: String),
   "sourceDir" .= ("app/code" :: String), "testDir" .= ("checks/generated" :: String),
   "verification" .= object ["layers" .= (["property","examples","model"] :: [String])],
   "nativeBindings" .= object ["functions" .= bindings],
   "sources" .= [object ["path" .= ("sample.lawspec" :: String), "content" .= source]]]))) of
  Just response -> response
  Nothing -> Null

planned :: String -> Either String Plan
planned source = either (Left . show) Right
  (compileCore 64 defaultGeneration [Source "prolog.lawspec" source] >>= planTesting)

-- | Prolog admission, ownership and native witness boundaries stay checked.
-- ref:REQ-prolog-target ref:DEC-prolog-janus
test_prologEmitter :: Spec
test_prologEmitter = describe "Prolog emitter admission" $ do
  it "registers checked public generation and respects nested output layouts" $ do
    let response = public [object ["declaration" .= ("sample::close" :: String),
          "native" .= (["application","close"] :: [String])]]
          "unit sample\nclose :: UInt8 -> UInt8\nlaw same is definition: for all (x :: UInt8) => close x must be x end for all end definition end law\nend unit"
    case response of
      Object fields -> do
        KM.lookup "diagnostics" fields `shouldBe` Just (Array mempty)
        let content = show (KM.lookup "files" fields)
        content `shouldSatisfy` isInfixOf "app/code/sample.py"
        content `shouldSatisfy` isInfixOf "checks/generated/test_sample_lawspec.pl"
        content `shouldNotSatisfy` isInfixOf "app/code/sample.pl"
        content `shouldSatisfy` isInfixOf "application.pl"
      _ -> expectationFailure (show response)
  it "rejects support namespaces publicly and case-insensitive artifact collisions" $ do
    let rejected source = case public [] source of
          Object fields -> KM.lookup "diagnostics" fields /= Just (Array mempty)
          _ -> False
    rejected "unit lawspec_prolog\nf :: UInt8 -> UInt8\nend unit" `shouldBe` True
    case planned "unit sample\nf :: UInt8 -> UInt8\nend unit" of
      Left message -> expectationFailure message
      Right plan -> prologFromPython plan
        [Artifact "src/a.py" "" "generated" "source", Artifact "src/A.py" "" "generated" "source"] `shouldSatisfy` isLeft
  it "uses checked metadata even when the host adapter text is unreadable" $
    case planned "unit sample\nclose :: UInt8 -> UInt16\nend unit" of
      Left message -> expectationFailure message
      Right plan -> case emitPlan "python" plan of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right python -> do
          let changed = [if ownership file == "user" then file {artifactContent = "not Python source"} else file | file <- python]
          case prologFromPython plan changed of
            Left diagnostics -> expectationFailure (show diagnostics)
            Right files -> do
              let bridge = concat [artifactContent file | file <- files, artifactPath file == "src/sample.py"]
              bridge `shouldSatisfy` isInfixOf "\"close\": _function0"
              bridge `shouldNotSatisfy` isInfixOf "not Python source"
              bridge `shouldSatisfy` isInfixOf "ls_close"
              mapM_ (\path -> map artifactPath files `shouldContain` [path])
                ["src/sample.pl", "src/lawspec_prolog.pl"]
  it "generates explicit production handler factories from checked ability metadata" $
    case planned "unit effects\nability Clock is\nnow :: Unit -> UInt8\nend ability\nend unit" of
      Left message -> expectationFailure message
      Right plan -> case prologFromPython plan [] of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right files -> do
          let code = concat [artifactContent f | f <- files, artifactPath f == "src/effects.py"]
          code `shouldSatisfy` isInfixOf "\"ClockHandler\": _production0"
          code `shouldSatisfy` isInfixOf "handler_ClockHandler_new"
          code `shouldSatisfy` isInfixOf "_bridge.Production.__init__(self,"
  it "validates definitions independently of optional law layers or host files" $
    case planned "unit sample\nfunction value (u :: Unit) -> UInt8 is 1 end function\nend unit" of
      Left message -> expectationFailure message
      Right plan -> do
        let corrupt d = d {C.definitionBody = (C.definitionBody d)
              {C.expressionNode = C.Constant (SInteger "UInt8" 300)}}
            forged = plan {plannedUnits = [u {plannedUnit = (plannedUnit u)
              {C.unitDefinitions = map corrupt (C.unitDefinitions (plannedUnit u))}} | u <- plannedUnits plan]}
        prologFromPython forged [] `shouldSatisfy` isLeft
  it "validates the logical view of materialized definitions and rejects forged witnesses" $
    case planned (unlines ["unit sample",
      "type Shown is one of Shown of type record{held :: a flag :: Bool} end type",
      "function create (flag :: Bool) -> Shown is Shown record{held = true, flag = flag} end function",
      "end unit"]) of
      Left message -> expectationFailure message
      Right logical -> do
        let native = witnessPlan logical
            corrupt expression = let value=C.mapChildren corrupt expression in case C.expressionNode value of
              C.Construct tag [payload,_] | tag==C.Id "sample::type::Shown::Shown" -> value
                {C.expressionNode=C.Construct tag [payload,C.Expr (C.scalarType "Text")
                  (C.Constant (textScalar "Int32")) (C.expressionOrigin value)]}
              _ -> value
            forged = native {plannedUnits=[u {plannedUnit=(plannedUnit u)
              {C.unitDefinitions=[d {C.definitionBody=corrupt (C.definitionBody d)} |
                d<-C.unitDefinitions (plannedUnit u)]}} | u<-plannedUnits native]}
        native `shouldNotBe` logical
        prologFromPython native [] `shouldSatisfy` isRight
        prologFromPython forged [] `shouldSatisfy` isLeft
