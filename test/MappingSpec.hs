-- Typed mapping obligations must survive ordinary lowering and law selection.
module MappingSpec (test_typedMappings) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Test.Hspec
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Value as V
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Frontend (compileCoreCanonical)

compileAt bits body=compileCoreCanonical bits S.defaultGeneration
  [S.Source "mapping.lawspec" ("unit example.mapping\n\n"++body ++ "\nend unit\n")]
checked bits body action=case compileAt bits body of
  Left diagnostics->expectationFailure (show diagnostics)
  Right program->action program
outcomes program=case (makeRegistry (C.programDataDeclarations program),prepareDefinitions program) of
  (Right registry,Right invoke)->forM_ (concatMap C.unitProperties (C.programUnits program)) $ \law->
    evaluateValueProposition registry (C.programMachineBits program) invoke [] (C.propertyBody law) `shouldBe` Right True
  _->expectationFailure "mapping did not retain a checked execution context"
declarations program=[C.declarationName d | u<-C.programUnits program,d<-C.unitDeclarations u]
rejects code body=case compileAt 64 body of
  Right _->expectationFailure "invalid mapping admitted"
  Left diagnostics->map S.code diagnostics `shouldContain` [code]
law name body="law "++name++" is definition: "++body++" end definition end law\n"
float bits="float64Bits(\""++bits++"\")"

test_typedMappings=describe "resolved typed mappings" $ do
  it "checks complete record keys and derives their checked preimages and inverse" $
    forM_ [32,64] $ \bits->checked bits (unlines
      ["mapping label of type record{enabled :: Bool} -> Text is",
       "row record{enabled = false}, \"off\"","row record{enabled = true}, \"on\"","end mapping",
       law "forward" "label record{enabled = true} = \"on\"",
       law "preimage" "labelPreimages \"off\" = [record{enabled = false}]",
       law "inverse" "labelInverse \"on\" = Present record{enabled = true}",
       law "absent" "labelInverse \"other\" = Absent"]) outcomes
  it "admits Eq collection keys with a fallback without requiring finite coverage" $
    checked 64 (unlines
      ["mapping label of type (List Bool) -> Text is row [false], \"off\" row [true], \"on\" otherwise \"other\" end mapping",
       law "matched" "label [true] = \"on\"",law "fallback" "label [true, false] = \"other\""]) $ \program->do
      declarations program `shouldNotContain` ["labelInverse","labelPreimages"]
      outcomes program
  it "uses set Eq for complete coverage and duplicate detection across storage orders" $ do
    checked 64 (unlines
      ["mapping label of type (Set Bool) -> Text is row #S{}, \"empty\" row #S{false}, \"off\" row #S{true}, \"on\" row #S{false, true}, \"both\" end mapping",
       law "reordered" "label #S{true, false} = \"both\"",
       law "inverse" "labelInverse \"both\" = Present #S{false, true}"]) outcomes
    rejects "mapping-duplicate"
      "mapping label of type (Set Bool) -> Text is row #S{false, true}, \"first\" row #S{true, false}, \"second\" otherwise \"other\" end mapping"
  it "compares records by typed labels and retains IEEE equality" $ do
    rejects "mapping-duplicate"
      "mapping label of type record{left :: Bool right :: UInt8} -> Text is row record{left = true, right = 1}, \"first\" row record{right = 1, left = true}, \"second\" otherwise \"other\" end mapping"
    rejects "mapping-duplicate" ("mapping label of type record{value :: Float64} -> Text is row record{value = "++float "8000000000000000"++"}, \"negative\" row record{value = "++float "0000000000000000"++"}, \"positive\" otherwise \"other\" end mapping")
    rejects "mapping-key" ("mapping label of type record{value :: Float64} -> Text is row record{value = "++float "7ff8000000000000"++"}, \"nan\" otherwise \"other\" end mapping")
  it "requires actual finite coverage and respects input restrictions" $ do
    rejects "mapping-coverage" "mapping label of type Bool -> Text is row true, \"on\" end mapping"
    rejects "mapping-coverage" "mapping label of type Integer -> Text is row 0, \"zero\" end mapping"
    checked 64 ("mapping label of type (flag :: Bool where flag) -> Text is row true, \"on\" end mapping\n"++
      law "selected" "label true = \"on\"") outcomes
    rejects "mapping-key" "mapping label of type (flag :: Bool where flag) -> Text is row false, \"off\" otherwise \"on\" end mapping"
    checked 64 ("mapping label of type (n :: Integer where n >= 0 and n <= 2) -> Text is row 0, \"zero\" row 1, \"one\" row 2, \"two\" end mapping\n"++
      law "selected" "label 2 = \"two\"") outcomes
  it "derives preimages for duplicate outputs but no unjustified inverse" $
    checked 64 (unlines
      ["mapping label of type Bool -> record{value :: Float64} is",
       "row false, record{value = "++float "8000000000000000"++"}",
       "row true, record{value = "++float "0000000000000000"++"}","end mapping",
       law "preimage" ("labelPreimages record{value = "++float "0000000000000000"++"} = [false, true]")]) $ \program->do
      declarations program `shouldContain` ["labelPreimages"]
      declarations program `shouldNotContain` ["labelInverse"]
      outcomes program
  it "removes unavailable inverse names from laws and documentary resolution" $ do
    let mapping="mapping label of type Bool -> Text is row false, \"same\" row true, \"same\" end mapping\n"
    compileAt 64 (mapping++law "invalid" "labelInverse \"same\" = Absent") `shouldSatisfy` isLeft
    compileAt 64 (mapping++"law documented is definition: true end definition references: ref function labelInverse end references end law\n") `shouldSatisfy` isLeft
  it "retains real declarations when a candidate inverse is unavailable and diagnoses real collisions" $ do
    let ordinary="function labelInverse (value :: Text) -> Bool is true end function\n"
    checked 64 (ordinary++"mapping label of type Bool -> Text is row false, \"same\" row true, \"same\" end mapping\n"++
      law "ordinary" "labelInverse \"same\" = true") outcomes
    compileAt 64 (ordinary++"mapping label of type Bool -> Text is row false, \"off\" row true, \"on\" end mapping") `shouldSatisfy` isLeft
  it "keeps builtin Maybe identities when local constructors have the same spelling" $
    checked 64 (unlines
      ["type Other is one of | Present of type Bool | Absent end type\n",
       "mapping label of type Bool -> Text is row false, \"off\" row true, \"on\" end mapping"]) $ \program->
        declarations program `shouldContain` ["labelInverse"]
  it "retains nominal construction boundaries and closed typed fields" $ do
    checked 64 (unlines
      ["type Flag is a record{enabled :: Bool} end type\n",
       "mapping label of type Flag -> Text is row Flag record{enabled = false}, \"off\" row Flag record{enabled = true}, \"on\" end mapping",
       law "selected" "label (Flag record{enabled = true}) = \"on\""]) outcomes
    compileAt 64 "type Flag is a record{enabled :: Bool} end type\nmapping label of type Flag -> Text is row record{enabled = true}, \"on\" otherwise \"off\" end mapping\n" `shouldSatisfy` isLeft
    compileAt 64 "mapping label of type record{value :: Nat} -> Text is row record{value = 0}, \"zero\" otherwise \"other\" end mapping" `shouldSatisfy` isLeft
  it "uses the selected machine width for contextual literals" $ do
    let body="mapping label of type UIntSize -> Text is row 4294967296, \"large\" otherwise \"other\" end mapping"
    compileAt 64 body `shouldSatisfy` isRight
    compileAt 32 body `shouldSatisfy` isLeft
  it "checks constant result restrictions even when the mapping input domain is empty" $
    compileAt 64 "mapping label of type (flag :: Bool where false) -> Nat is otherwise 0 end mapping" `shouldSatisfy` isLeft
  it "does not capture a predicate whose ordinary name resembles a generated argument" $
    checked 64 (unlines
      ["function lawspecMappingInput (value :: UInt8) -> Bool is value > 0 end function\n",
       "mapping label of type Bool -> record{value :: (n :: UInt8 where lawspecMappingInput n)} is",
       "row false, record{value = 1}","row true, record{value = 2}","end mapping",
       law "selected" "(label true).value = 2"]) outcomes
  it "resolves qualified payload constructors before deriving finite coverage" $ do
    let library=S.Source "library.lawspec" "unit library\n\ntype Switch is one of | Missing | Value of type Bool end type\nend unit\n"
        consumer=S.Source "consumer.lawspec" (unlines
          ["unit consumer","import library as lib (Switch)",
           "mapping label of type Switch -> Text is row lib.Missing, \"missing\" row lib.Value false, \"off\" row lib.Value true, \"on\" end mapping",
           law "selected" "label (lib.Value true) = \"on\"", "end unit"])
    case compileCoreCanonical 64 S.defaultGeneration [library,consumer] of
      Left diagnostics->expectationFailure (show diagnostics)
      Right program->outcomes program
  it "resolves aliases before checking key restrictions and helper result contracts" $
    checked 64 (unlines
      ["refinement Enabled is (flag :: Bool where flag) end refinement\n",
       "mapping label of type Enabled -> Text is row true, \"on\" end mapping",
       law "preimage" "labelPreimages \"on\" = [true]",
       law "inverse" "labelInverse \"on\" = Present true"]) outcomes
  it "retains every refined key in a shared output class" $
    checked 64 (unlines
      ["mapping label of type (n :: Integer where n >= 0 and n <= 2) -> Text is",
       "row 0, \"same\" row 1, \"same\" row 2, \"other\" end mapping",
       law "preimage" "labelPreimages \"same\" = [0, 1]"]) outcomes
  it "covers every UInt8 value without treating sampled representatives as complete" $ do
    let mapping=unlines (["mapping number of type UInt8 -> UInt16 is"]++
          ["row "++show n++", "++show n | n<-[0::Int ..255]]++["end mapping"])
    checked 64 (mapping++law "last" "number 255 = 255"++
      law "preimage" "numberPreimages 255 = [255]"++
      law "inverse" "numberInverse 255 = Present 255"++
      law "absent" "numberInverse 256 = Absent") outcomes
    rejects "mapping-coverage" (unlines (["mapping number of type UInt8 -> UInt16 is"]++
      ["row "++show n++", "++show n | n<-[0::Int ..254]]++["end mapping"]))
  it "admits a fallback without rows and retains rejection of unsupported bodyless definitions" $ do
    checked 64 ("mapping label of type (List Bool) -> Text is otherwise \"other\" end mapping\n"++
      law "fallback" "label [true, false] = \"other\"") outcomes
    compileAt 64 "mapping label of type (flag :: Bool where false) -> Text is end mapping" `shouldSatisfy` isLeft
  it "does not derive an inverse for nonreflexive outputs" $
    checked 64 ("mapping label of type Bool -> Float64 is row false, "++float "7ff8000000000000"++
      " row true, "++float "0000000000000000"++" end mapping\n"++
      law "nanPreimages" ("labelPreimages ("++float "7ff8000000000000"++") = ([] :: List Bool)")) $ \program->do
        declarations program `shouldNotContain` ["labelInverse"]
        outcomes program
  it "resolves available helpers through imported facades and rejects unavailable imports" $ do
    let library rows=S.Source "library.lawspec" ("unit library\nmapping label of type Bool -> Text is "++rows++" end mapping\nend unit")
        facade=S.Source "facade.lawspec" "unit facade\nimport library (labelPreimages, labelInverse)\nexport labelPreimages, labelInverse\nend unit"
        consumer=S.Source "consumer.lawspec" ("unit consumer\nimport facade (labelPreimages, labelInverse)\n"++
          law "preimage" "labelPreimages \"on\" = [true]"++law "inverse" "labelInverse \"on\" = Present true"++"\nend unit\n")
        compile rows=compileCoreCanonical 64 S.defaultGeneration [library rows,facade,consumer]
    case compile "row false, \"off\" row true, \"on\"" of
      Left diagnostics->expectationFailure (show diagnostics)
      Right program->outcomes program
    compile "row false, \"same\" row true, \"same\"" `shouldSatisfy` isLeft
  it "retains phrase names on the mapping and its derived helpers" $
    checked 64 ("mapping \"|delivery label| of type Bool -> Text is row false, \"off\" row true, \"on\" end mapping\n"++
      law "inverse" "\"|delivery label inverse| \"on\" = Present true"++
      law "preimage" "\"|delivery label preimages| \"off\" = [false]") outcomes
  it "groups equal set outputs without imposing their stored iteration order" $
    checked 64 ("mapping label of type Bool -> Set Bool is row false, #S{false, true} row true, #S{true, false} end mapping\n"++
      law "preimage" "labelPreimages #S{true, false} = [false, true]") $ \program->do
        declarations program `shouldNotContain` ["labelInverse"]
        outcomes program
