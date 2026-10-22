-- | Configuration generation must retain checked values and reject constraints
-- outside the target's vocabulary. Native validators are exercised separately.
-- ref:REQ-artifact-targets
module ArtifactTargetSpec (test_artifactTargets) where

import Data.Aeson (Value(..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as B
import Data.Either (isLeft)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Test.Hspec
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Core as C
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (Plan(..), PlannedUnit(..), planTesting)
import LawSpec.CoreEmit (emitPlanWithLayout)
import LawSpec.ArtifactEmit (emitArtifacts)
import LawSpec.Scalar (Scalar(..))

emit :: String -> String -> Either String [Artifact]
emit target source = either (Left . show) Right $ do
  core <- compileCore 64 defaultGeneration [Source "configuration.lawspec" source]
  plan <- planTesting core
  emitPlanWithLayout target Nothing Nothing plan

source :: String
source = unlines
  [ "unit configuration"
  , "type Settings is a record{port :: UInt16 enabled :: Bool hosts :: List Text} end type"
  , "function settings (unused :: Unit) -> Settings is"
  , "  Settings record{port = 8080, enabled = true, hosts = [\"localhost\", \"${do_not_interpolate}\"]}"
  , "end function"
  , "end unit" ]

contents :: String -> [Artifact] -> String
contents path files = concat [artifactContent a | a <- files, artifactPath a == path]

-- | Configuration, grammar and pipeline artifacts retain checked semantics.
-- ref:REQ-artifact-targets
test_artifactTargets :: Spec
test_artifactTargets = describe "artifact targets" $ do
  it "evaluates checked Unit functions into YAML 1.2 without interpolation" $ case emit "yaml" source of
    Left message -> expectationFailure message
    Right files -> do
      contents "configuration.yaml" files `shouldSatisfy` isInfixOf "8080"
      contents "configuration.yaml" files `shouldSatisfy` isInfixOf "${do_not_interpolate}"
      decode (B.pack (contents "configuration.schema.json" files)) `shouldSatisfy`
        (\value -> case value of Just (Object fields) -> KM.member "$defs" fields; _ -> False)
  it "emits integer and null validation for Terraform variables" $ case emit "hcl" source of
    Left message -> expectationFailure message
    Right files -> do
      contents "variables.tf" files `shouldSatisfy` isInfixOf "65535"
      contents "variables.tf" files `shouldSatisfy` isInfixOf "nullable = false"
      contents "variables.tf" files `shouldSatisfy` isInfixOf "floor("
  it "rejects loss of unsupported scalar semantics" $
    emit "yaml" (unlines ["unit unsupported", "value :: Unit -> Rational", "end unit"]) `shouldSatisfy` isLeft
  it "refuses HCL representations that cannot preserve unbounded integers or literal normalization" $ do
    emit "hcl" "unit exact\nvalue :: Unit -> Integer\nend unit" `shouldSatisfy` isLeft
    emit "hcl" "unit exact\nfunction value (u :: Unit) -> Text is \"e\x0301\" end function\nend unit" `shouldSatisfy` isLeft
  it "rejects invalid definitions even when the selected target does not run tests" $
    emit "make" (unlines ["unit invalid", "function bad (u :: Unit) -> UInt8 is 300 end function", "end unit"]) `shouldSatisfy` isLeft
  it "generates ordered phony check, generation and execution stages" $ case emit "make" source of
    Left message -> expectationFailure message
    Right files -> do
      contents "Makefile" files `shouldSatisfy` isInfixOf "generate: check"
      contents "Makefile" files `shouldSatisfy` isInfixOf "test: generate"
  it "exports concrete ANTLR input types with matching typed entry points and schemas" $ do
    input <- readFile "test/fixtures/artifact-antlr-inputs.lawspec"
    case emit "antlr4" input of
      Left message -> expectationFailure message
      Right files -> do
        let grammar = contents "LawSpecData.g4" files
        grammar `shouldSatisfy` isInfixOf "inputOnly::type::Box::Box"
        case (decode (B.pack (contents "lawspec-artifacts.json" files)),
              decode (B.pack (contents "data.schema.json" files))) of
          (Just (Object manifest), Just (Object schema)) ->
            case (KM.lookup "types" manifest, KM.lookup "entryPoints" manifest, KM.lookup "$defs" schema) of
              (Just (Object types), Just (Object points), Just (Object definitions)) -> do
                KM.keys points `shouldMatchList` KM.keys types
                mapM_ (\name -> show types `shouldSatisfy` isInfixOf name) ["UInt8", "UInt16", "List"]
                mapM_ (\(key, point) -> case point of
                  Object fields -> case (KM.lookup "rule" fields, KM.lookup "schema" fields) of
                    (Just (String rule), Just (String reference)) -> do
                      grammar `shouldSatisfy` isInfixOf (T.unpack rule ++ " : " ++ K.toString key ++ " EOF ;")
                      reference `shouldBe` "#/$defs/" <> K.toText key
                      KM.member key definitions `shouldBe` True
                    _ -> expectationFailure "typed ANTLR entry lacks its rule or schema reference"
                  _ -> expectationFailure "typed ANTLR entry is not an object") (KM.toList points)
              _ -> expectationFailure "ANTLR type, entry or definition metadata is missing"
          _ -> expectationFailure "ANTLR metadata is not JSON objects"
  it "reports closed indexed ANTLR input types as unsupported" $ do
    input <- readFile "test/fixtures/artifact-antlr-indexed-input.lawspec"
    case emit "antlr4" input of
      Left message -> message `shouldSatisfy` isInfixOf "ANTLR indexed/opaque data syntax is unsupported"
      Right _ -> expectationFailure "an indexed input was omitted instead of diagnosed"
  it "keeps incomplete configuration distinct from a checked document" $
    case emit "yaml" "unit incomplete\nsetting :: Unit -> UInt16\nend unit" of
      Left message -> expectationFailure message
      Right files -> do
        map artifactPath files `shouldNotContain` ["configuration.yaml"]
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "\"configurationComplete\":false"
  it "preserves an empty data type as an unsatisfiable schema" $
    case emit "yaml" "unit empty\ntype Empty is one of end type\nend unit" of
      Left message -> expectationFailure message
      Right files -> contents "configuration.schema.json" files `shouldSatisfy` isInfixOf ":false"
  it "identifies type-only HCL variables and their missing inputs" $
    case emit "hcl" "unit types\ntype Settings is a record{port :: UInt16} end type\nend unit" of
      Left message -> expectationFailure message
      Right files -> do
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "\"configurationComplete\":false"
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "\"missingTypeValues\":[\"type_"
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "types::type::Settings"
  it "requires definition admission at every public artifact emitter" $
    case compileCore 64 defaultGeneration [Source "valid.lawspec"
          "unit checked\nfunction amount (u :: Unit) -> UInt8 is 1 end function\nend unit"] >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        let corrupt d = d {C.definitionBody = (C.definitionBody d)
              {C.expressionNode = C.Constant (SInteger "UInt8" 300)}}
            forged = plan {plannedUnits = [u {plannedUnit = (plannedUnit u)
              {C.unitDefinitions = map corrupt (C.unitDefinitions (plannedUnit u))}} | u <- plannedUnits plan]}
        mapM_ (\target -> emitPlanWithLayout target Nothing Nothing forged `shouldSatisfy` isLeft)
          ["hcl","yaml","antlr4","make"]
        mapM_ (\target -> emitArtifacts False target Nothing Nothing forged `shouldSatisfy` isLeft)
          ["hcl","yaml","antlr4","make"]
