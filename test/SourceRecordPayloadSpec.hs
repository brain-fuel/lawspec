-- | Structural nominal payloads retain authored types through inference,
-- specialization, table validation and mandatory constructor admission.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module SourceRecordPayloadSpec (test_structuralNominalPayloads) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isPrefixOf)
import LawSpec.SourceText (formatSource)
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCoreCanonical)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BL
import qualified LawSpec.Public as Public
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValue,evaluateValueProposition)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting,plannedUnits,plannedProperties,plannedProperty)
import SourceRecordPayloadFixtures (payloadSource)

compile body=compileCoreCanonical 64 S.defaultGeneration [S.Source "payloads.lawspec" ("unit example.payloads\n"++body)]
checked source action=either (expectationFailure . show) action source

checkOutcomes bits candidate = do
  validateProgram candidate `shouldBe` Right ()
  case (planTesting candidate,makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate) of
    (Right plan,Right registry,Right invoke) -> do
      forM_ [p | u<-plannedUnits plan,p<-plannedProperties u,null (C.propertyInputs (plannedProperty p))] $ \planned ->
        evaluateValueProposition registry bits invoke [] (C.propertyBody (plannedProperty planned)) `shouldBe` Right True
      forM_ [example | u<-C.programUnits candidate,property<-C.unitProperties u,example<-C.propertyExamples property] $ \example -> do
        bindings<-either (\message -> expectationFailure message >> pure []) pure
          (mapM (\(name,value)->(,) name <$> evaluateValue registry bits invoke [] value) (C.exampleBindings example))
        forM_ (C.exampleExpectations example) $ \expectation ->
          evaluateValueProposition registry bits invoke bindings expectation `shouldBe` Right True
      forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
    _ -> expectationFailure "structural nominal payload program did not admit"

test_structuralNominalPayloads = describe "structural nominal payloads" $ do
  it "checks actual named-record and alternative payloads, generic extraction and literal tables" $
    forM_ [32,64] $ \bits -> checked
      (compileCoreCanonical bits S.defaultGeneration [S.Source "payloads.lawspec" payloadSource]) (checkOutcomes bits)
  it "wraps record headers and named closers without changing declaration nesting" $ do
    let formatted=formatSource (S.Source "payloads.lawspec" payloadSource)
        formattedLines=lines (S.content formatted)
    formatSource formatted `shouldBe` formatted
    length (filter ("type " `isPrefixOf`) formattedLines) `shouldBe` 4
    length (filter ("function " `isPrefixOf`) formattedLines) `shouldBe` 5
    length (filter ("law " `isPrefixOf`) formattedLines) `shouldBe` 8
    compileCoreCanonical 64 S.defaultGeneration [formatted] `shouldSatisfy` isRight
  it "normalizes parameterized nominal storage idempotently" $
    checked (compileCoreCanonical 64 S.defaultGeneration [S.Source "payloads.lawspec" payloadSource]) $ \candidate -> do
      let once=normalizeProgramRecords candidate
      once `shouldSatisfy` isRight
      (once >>= normalizeProgramRecords) `shouldBe` once
  it "checks whole structural results and generic alternative table bindings" $
    checked (compile (unlines
      ["type Box (a of type Type) is one of | Box of type record{value of type a} end type",
       "function payload (box of type Box a) -> record{value of type a} is",
       "first matching case of box: when Box value then value end case end function",
       "law direct is definition: payload (Box record{value = \"note\"}) = record{value = \"note\"} end end",
       "law rows is definition: for all (box of type Box Text) => payload box = payload box end end",
       "expect (payload box).value = expected in table (box, expected):",
       "row Box record{value = \"note\"}, \"note\"","end end"])) $ \candidate -> do
      checkOutcomes 64 candidate
      BL.length (A.encode (Public.programView S.defaultGeneration [] [] [] [] candidate)) `shouldSatisfy` (>0)
  it "preserves GADT field types and branch-local equations for structural payloads" $
    checked (compile (unlines
      ["type Value (a of type Type) is one of",
       "| Number of type record{value of type Integer} where a = Integer",
       "| Truth of type record{value of type Bool} where a = Bool","end type",
       "function read (expression of type Value a) -> a is",
       "first matching case of expression:",
       "when Number record{value = number} then number",
       "when Truth record{value = boolean} then boolean","end case end function",
       "law number is definition: read (Number record{value = 7}) = 7 end end",
       "law truth is definition: read (Truth record{value = true}) = true end end"])) (checkOutcomes 64)
  it "preserves structural record types in GADT result equations" $
    checked (compile (unlines
      ["type Tagged (a of type Type) is one of",
       "| Tagged of type Bool where a = record{value of type Integer}","end type",
       "function flag (tagged of type Tagged record{value of type Integer}) -> Bool is",
       "first matching case of tagged: when Tagged enabled then enabled end case end function",
       "law selected is definition: flag (Tagged true) = true end end"])) (checkOutcomes 64)
  it "keeps unknown fields, closed products and nominal boundaries checked" $ do
    let declarations=unlines ["type Delivery is one of | Download of type record{count of type UInt8} end type",
          "function count (delivery of type Delivery) -> UInt8 is first matching case of delivery:",
          "when Download record{count = value} then value end case end function"]
    forM_ ["Download record{}","Download record{count = 256}","Download record{count = 1, extra = true}"] $ \value ->
      compile (declarations++"law invalid is definition: count ("++value++") = 1 end end") `shouldSatisfy` isLeft
    compile (unlines ["type Number is a record{count of type Integer} end type",
      "type Delivery is one of | Download of type record{count of type Integer} end type",
      "law invalid is definition: Download (Number record{count = 1}) = Download record{count = 1} end end"]) `shouldSatisfy` isLeft
  it "audits unused computations and positive fields in structural payloads" $ do
    compile (unlines ["type Delivery is one of | Download of type record{document of type Text unused of type Integer} end type",
      "function invalid (ignored of type ()) -> Delivery is Download record{document = \"paper\", unused = 1 / 0} end function"]) `shouldSatisfy` isLeft
    compile (unlines ["type Delivery is one of | Download of type record{count of type Nat} end type",
      "function invalid (ignored of type ()) -> Delivery is Download record{count = 0} end function"]) `shouldSatisfy` isLeft
  it "checks capabilities against completed constructor shapes" $ do
    let source field=unlines ["type Task is one of | Task of type record{"++field++"} end type",
          "type Gate is a record{check of type record{task of type (value of type Task where value = value)}} end type"]
    compile (source "value of type Integer") `shouldSatisfy` isRight
    compile (source "run of type (Integer -> Integer)") `shouldSatisfy` isLeft
