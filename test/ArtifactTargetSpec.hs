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
      -- Block style, in spec order, with text always double-quoted.
      contents "configuration.yaml" files `shouldSatisfy` isInfixOf
        "\"configuration::settings\":\n  port: 8080\n  enabled: true\n  hosts:\n    - \"localhost\"\n"
      contents "configuration.yaml" files `shouldSatisfy` isInfixOf "# settings \8212 configuration.lawspec:3\n"
      decode (B.pack (contents "configuration.schema.json" files)) `shouldSatisfy`
        (\value -> case value of Just (Object fields) -> KM.member "$defs" fields; _ -> False)
  it "emits integer and null validation for Terraform variables" $ case emit "hcl" source of
    Left message -> expectationFailure message
    Right files -> do
      contents "variables.tf" files `shouldSatisfy` isInfixOf "65535"
      contents "variables.tf" files `shouldSatisfy` isInfixOf "nullable = false"
      contents "variables.tf" files `shouldSatisfy` isInfixOf "floor("
      -- Named from the source, with a message per restriction.
      contents "variables.tf" files `shouldSatisfy` isInfixOf "variable \"settings\" {\n  type = object({\n    port    = number\n"
      contents "variables.tf" files `shouldSatisfy` isInfixOf
        "error_message = \"The value of settings.port must be a whole number from 0 to 65535 (UInt16).\""
      contents "configuration.tfvars.json" files `shouldSatisfy` isInfixOf "{\n  \"settings\": {\n    \"port\": 8080,"
  it "writes a record's rules as JSON Schema keywords" $ do
    let ruled = unlines
          [ "unit configuration"
          , "type Account is a record{"
          , "  code :: (v :: Text where v matches regex \"[A-Z]{2}.[0-9]+\" && prelude.length v <= 8 && 4 <= prelude.length v),"
          , "  id :: (v :: Text where v matches format uuid),"
          , "  plan :: (v :: Text where v in [\"free\", \"pro\"]),"
          , "  seats :: (v :: Int32 where 1 <= v && v < 100)}"
          , "end type"
          -- A length is proved from a condition, not from a literal.
          , "function coded (code :: Text) -> Maybe Account is"
          , "  if code matches regex \"[A-Z]{2}.[0-9]+\" then"
          , "    if prelude.length code <= 8 then"
          , "      if 4 <= prelude.length code then"
          , "        Present (Account record{code = code, id = \"01234567-89ab-cdef-0123-456789ABCDEF\", plan = \"pro\", seats = 3})"
          , "      else Absent end if"
          , "    else Absent end if"
          , "  else Absent end if"
          , "end function"
          , "function account (unused :: Unit) -> Maybe Account is coded \"GB-12\" end function"
          , "end unit" ]
    case emit "yaml" ruled of
      Left message -> expectationFailure message
      Right files -> do
        let schema = contents "configuration.schema.json" files
        -- Anchored, and the dialect's `.` spelled out for ECMA-262.
        schema `shouldSatisfy` isInfixOf "\"pattern\": \"^(?:[A-Z]{2}[^\\\\n][0-9]+)$\""
        schema `shouldSatisfy` isInfixOf "\"maxLength\": 8"
        schema `shouldSatisfy` isInfixOf "\"minLength\": 4"
        schema `shouldSatisfy` isInfixOf "^(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
        schema `shouldSatisfy` isInfixOf "\"enum\": [\n"
        schema `shouldSatisfy` isInfixOf "\"exclusiveMaximum\": 100"
        decode (B.pack schema) `shouldSatisfy` (\value -> case value of Just (Object _) -> True; _ -> False)
  it "writes the email format exactly and refuses the strict one" $ do
    let contact format mask = unlines
          [ "unit configuration"
          , "type Contact is a record{address :: (v :: Text where v matches format " ++ format ++ ")} end type"
          , "masking Contact is"
          , "  address shown as " ++ mask
          , "end masking"
          , "function contact (unused :: Unit) -> Contact is Contact record{address = \"ann@example.org\"} end function"
          , "end unit" ]
    case emit "yaml" (contact "email" "hash blake3") of
      Left message -> expectationFailure message
      Right files -> do
        let schema = contents "configuration.schema.json" files
        -- The format's three checks, each as its keyword: nothing weaker.
        schema `shouldSatisfy` isInfixOf "\"pattern\": \"^(?:(?:[A-Za-z0-9!#$%&'*+/=?^_`{|}~\\\\-]+"
        schema `shouldSatisfy` isInfixOf "\"pattern\": \"^(?:[\\\\s\\\\S]{1,64}@[^@]*)$\""
        schema `shouldSatisfy` isInfixOf "\"maxLength\": 254"
        schema `shouldSatisfy` isInfixOf "\"address\": \"hash blake3\""
    case emit "yaml" (contact "email" "hash") of
      Left message -> expectationFailure message
      Right files -> contents "configuration.schema.json" files `shouldSatisfy` isInfixOf "\"address\": \"hash\""
    case emit "yaml" (contact "rfc822Address" "hidden") of
      Left message -> message `shouldSatisfy` isInfixOf "cannot express the format rfc822Address of address"
      Right _ -> expectationFailure "expected the strict format to be refused"
  it "annotates a masked record's schema with how each field is shown" $ do
    let masked = unlines
          [ "unit configuration"
          , "type Card is a record{number :: Text, contact :: Text, pin :: Int32} end type"
          , "masking Card is"
          , "  number shown as last 4"
          , "  contact shown as email"
          , "  pin shown as hidden"
          , "end masking"
          , "function card (unused :: Unit) -> Card is Card record{number = \"4111\", contact = \"a@b.example\", pin = 1} end function"
          , "end unit" ]
    case emit "yaml" masked of
      Left message -> expectationFailure message
      Right files -> do
        let schema = contents "configuration.schema.json" files
        schema `shouldSatisfy` isInfixOf "\"x-lawspec-masking\": {\n"
        schema `shouldSatisfy` isInfixOf "\"number\": \"last 4\""
        schema `shouldSatisfy` isInfixOf "\"contact\": \"email\""
        schema `shouldSatisfy` isInfixOf "\"pin\": \"hidden\""
        -- The value itself is the wire form.
        contents "configuration.yaml" files `shouldSatisfy` isInfixOf "4111"
  it "refuses a rule JSON Schema cannot express, naming the target" $ do
    let crossed = unlines
          [ "unit configuration"
          , "type Range is a record{low :: Int32, high :: (v :: Int32 where low <= v)} end type"
          , "function range (unused :: Unit) -> Range is Range record{low = 1, high = 2} end function"
          , "end unit" ]
    case emit "yaml" crossed of
      Left message -> do
        message `shouldSatisfy` isInfixOf "target-unsupported"
        message `shouldSatisfy` isInfixOf "configuration schema cannot express constructor predicate"
      Right _ -> expectationFailure "expected the cross-field rule to be refused"
  it "rejects loss of unsupported scalar semantics" $
    emit "yaml" (unlines ["unit unsupported", "value :: Unit -> Rational", "end unit"]) `shouldSatisfy` isLeft
  it "restricts HCL to entry reachability while retaining type-only input units" $ do
    let extra = "type Unused is one of A | B end type\n"
        library = "unit boundary\n" ++ extra
        entry = "function port (unused :: Unit) -> UInt16 is 8080 end function\n"
    case emit "hcl" (library ++ entry ++ "end unit") of
      Left message -> expectationFailure message
      Right files -> do
        contents "variables.tf" files `shouldSatisfy` isInfixOf "variable \"port\""
        contents "variables.tf" files `shouldNotSatisfy` isInfixOf "type_unused"
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "not reachable from any configuration entry"
    emit "hcl" (library ++ "value :: Unit -> Unused\nend unit") `shouldSatisfy` isLeft
    emit "hcl" (library ++ "type Settings is a record{choice :: Unused} end type\nvalue :: Unit -> Settings\nend unit") `shouldSatisfy` isLeft
    emit "hcl" (library ++ "end unit") `shouldSatisfy` isLeft
    emit "hcl" (library ++ entry ++ "function invalid (x :: Int32) -> Rational is 1 / 0 end function\nend unit") `shouldSatisfy` isLeft
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
      contents "Makefile" files `shouldSatisfy` isInfixOf "# Generated by LawSpec from configuration.lawspec. Do not edit.\n"
  it "exports concrete ANTLR input types with matching typed entry points and schemas" $ do
    input <- readFile "test/fixtures/artifact-antlr-inputs.lawspec"
    case emit "antlr4" input of
      Left message -> expectationFailure message
      Right files -> do
        let grammar = contents "LawSpecData.g4" files
        grammar `shouldSatisfy` isInfixOf "inputOnly::type::Box::Box"
        -- Rules are named after their types, in the order the spec uses them.
        grammar `shouldSatisfy` isInfixOf "boxUint8\n    : 'inputOnly::type::Box::Box' '(' uint8 ')'\n    ;"
        grammar `shouldSatisfy` isInfixOf "listBoxBool\n    : '[' (boxBool (',' boxBool)*)? ']'\n    ;"
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
                      grammar `shouldSatisfy` isInfixOf (T.unpack rule ++ "\n    : " ++ K.toString key ++ " EOF\n    ;")
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
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "\"configurationComplete\": false"
  it "preserves an empty data type as an unsatisfiable schema" $
    case emit "yaml" "unit empty\ntype Empty is one of end type\nend unit" of
      Left message -> expectationFailure message
      Right files -> contents "configuration.schema.json" files `shouldSatisfy` isInfixOf "\"empty\": false"
  it "identifies type-only HCL variables and their missing inputs" $
    case emit "hcl" "unit types\ntype Settings is a record{port :: UInt16} end type\nend unit" of
      Left message -> expectationFailure message
      Right files -> do
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "\"configurationComplete\": false"
        contents "lawspec-artifacts.json" files `shouldSatisfy` isInfixOf "\"missingTypeValues\": [\n    \"type_settings\"\n  ]"
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
