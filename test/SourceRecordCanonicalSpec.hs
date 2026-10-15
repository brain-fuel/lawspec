-- | Canonical structural products reach parsing, imports, template admission,
-- specialization, examples and the same checked Core used by every target.
-- ref:DEC-readable-notation ref:DEC-typed-core-boundary ref:DEC-total-definitions
module SourceRecordCanonicalSpec (test_canonicalRecordsReachCheckedCore,recordSource) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isPrefixOf)
import qualified Data.ByteString.Lazy as BL
import Data.Binary (encode,decode)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Foldable as F
import qualified LawSpec.Public as Public
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValue,evaluateValueProposition)
import LawSpec.Core.Value (Value(..))
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting,plannedUnits,plannedProperties,plannedProperty)
import LawSpec.SourceText (formatSource)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Persist ()
import SourceRecordCanonicalFixtures (recordSource)

compile body=compileCoreCanonical 64 S.defaultGeneration [S.Source "records.lawspec" ("unit example.records\n"++body)]
checked source action=either (expectationFailure . show) action source

-- Canonical anonymous record syntax is not a nominal coercion.
test_canonicalRecordsReachCheckedCore = describe "canonical anonymous records" $ do
  it "compiles real source, checked generic definitions and record-valued table rows" $
    forM_ [32,64] $ \bits -> checked (compileCoreCanonical bits S.defaultGeneration [S.Source "records.lawspec" recordSource]) $ \candidate -> do
      validateProgram candidate `shouldBe` Right ()
      let laws=concatMap C.unitProperties (C.programUnits candidate)
      length laws `shouldBe` 5
      length (C.propertyExamples (head laws)) `shouldBe` 3
      case (planTesting candidate,makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate) of
        (Right plan,Right registry,Right invoke) -> do
          forM_ [p | u<-plannedUnits plan,p<-plannedProperties u, null (C.propertyInputs (plannedProperty p))] $ \planned ->
            evaluateValueProposition registry bits invoke [] (C.propertyBody (plannedProperty planned)) `shouldBe` Right True
          forM_ (C.propertyExamples (head laws)) $ \example -> do
            bindings<-either (\message -> expectationFailure message >> pure []) pure (mapM (\(name,value)->(,) name <$> evaluateValue registry bits invoke [] value) (C.exampleBindings example))
            forM_ (C.exampleExpectations example) $ \expectation ->
              evaluateValueProposition registry bits invoke bindings expectation `shouldBe` Right True
          forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
        _ -> expectationFailure "canonical record program did not admit"
  it "exports concrete record table bindings through lexical construction lets" $
    checked (compileCoreCanonical 64 S.defaultGeneration [S.Source "records.lawspec" recordSource]) $ \candidate ->
      case Public.programView S.defaultGeneration [] [] [] [] candidate of
        A.Object response | Just (A.Array laws)<-KM.lookup "laws" response ->
          case F.toList laws of
            A.Object law:_ | Just (A.Array examples)<-KM.lookup "examples" law -> do
              let fieldValues=[value | A.Object example<-F.toList examples,
                    Just (A.Array bindings)<-[KM.lookup "bindings" example],A.Object binding<-F.toList bindings,
                    Just (A.Object record)<-[KM.lookup "value" binding],
                    Just (A.Array fields)<-[KM.lookup "fields" record],value<-F.toList fields]
              fieldValues `shouldBe` [A.toJSON (SInteger "Integer" n) | n<-[-1,0,1]]
            _ -> expectationFailure "missing public record examples"
        _ -> expectationFailure "missing public record laws"
  it "retains closed field sets, nominal boundaries and exact scalar contexts" $ do
    let good=unlines ["function accept (x of type record{n of type UInt8}) -> UInt8 is x.n end function",
          "law small is definition: accept record{n = 255} = 255 end end"]
    compile good `shouldSatisfy` isRight
    forM_ ["accept record{n = 256}","accept record{}","accept record{n = 1, extra = true}"] $ \expression ->
      compile (unlines ["function accept (x of type record{n of type UInt8}) -> UInt8 is x.n end function",
        "law invalid is definition: "++expression++" = 1 end end"]) `shouldSatisfy` isLeft
    compile (unlines ["type Picture is a record{n of type Integer} end type",
      "function accept (x of type Picture) -> Integer is x.n end function",
      "law invalid is definition: accept record{n = 1} = 1 end end"]) `shouldSatisfy` isLeft
  it "audits literal-only fields in unused checked definitions" $ do
    compile "function bad (ignored of type ()) -> Integer is record{safe = 1, unused = 1 / 0}.safe end function" `shouldSatisfy` isLeft
    compile "function good (ignored of type ()) -> Integer is record{safe = 1, unused = 1 / 1}.safe end function" `shouldSatisfy` isRight
  it "keeps ordinary record identifiers and prefix calls with a bare record argument" $
    compile (unlines ["function record (x of type record{n of type Integer}) -> Integer is x.n end function",
      "law selected is definition: record record{n = 7} = 7 end end"]) `shouldSatisfy` isRight
  it "keeps caller values in nested named record construction" $
    checked (compile (unlines ["type Number is a record{amount of type Integer} end type",
      "type Pair is a record{first of type Number second of type Number} end type",
      "function choose (value of type Integer) -> Integer is",
      "  (Pair record{first = Number record{amount = 0}, second = Number record{amount = value}}).second.amount end function",
      "law selected is definition: choose 7 = 7 end end"])) $ \candidate ->
        case (makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate) of
          (Right registry,Right invoke) -> forM_ (concatMap C.unitProperties (C.programUnits candidate)) $ \law ->
            evaluateValueProposition registry 64 invoke [] (C.propertyBody law) `shouldBe` Right True
          _ -> expectationFailure "named construction did not admit"
  it "retains intrinsic positive fields and rejects invalid record example inputs" $ do
    let source amount=unlines ["law selected is definition:",
          "for all (value of type record{count of type Nat}) => value.count = value.count end end",
          "expect value.count = expected in table (value, expected):",
          "row record{count = "++show amount++"}, "++show amount,"end end"]
    compile (source 1) `shouldSatisfy` isRight
    compile (source 0) `shouldSatisfy` isLeft
  it "resolves imported constructors inside record-valued tables" $ do
    let library=S.Source "library.lawspec" "unit library\ntype Color is one of | Red | Blue end type\n"
        consumer=S.Source "consumer.lawspec" (unlines ["unit consumer","import library as colors (Color)",
          "law selected is definition: for all (value of type record{color of type Color}) => value = value end end",
          "expect value = expected in table (value, expected):",
          "row record{color = Red}, record{color = Red}","row record{color = Blue}, record{color = Blue}","end end"])
    checked (compileCoreCanonical 64 S.defaultGeneration [library,consumer]) $ \candidate ->
      validateProgram candidate `shouldBe` Right ()
  it "preserves IEEE equality and rejects non-reflexive record mapping keys" $ do
    let nan="float64Bits(\"7ff8000000000000\")"
    checked (compile ("law selected is definition: must not record{n = "++nan++"} = record{n = "++nan++"} end end")) $ \candidate ->
      case (makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate) of
        (Right registry,Right invoke) -> forM_ (concatMap C.unitProperties (C.programUnits candidate)) $ \law ->
          evaluateValueProposition registry 64 invoke [] (C.propertyBody law) `shouldBe` Right True
        _ -> expectationFailure "IEEE record program did not admit"
    compile (unlines ["mapping lookup of type record{n of type Float64} -> Bool is",
      "row record{n = "++nan++"}, true","otherwise false","end mapping"]) `shouldSatisfy` isLeft
  it "distinguishes empty products from Unit, including in record-valued examples" $ do
    compile (unlines ["law selected is definition: for all (value of type record{done of type ()}) => value = value end end",
      "expect value = record{done = ()} in table (value):","row record{done = ()}","end end"]) `shouldSatisfy` isRight
    compile "law selected is definition: record{} = () end end" `shouldSatisfy` isLeft
  it "formats canonical records and table literals idempotently without changing outcomes" $ do
    let source=S.Source "records.lawspec" recordSource
        formatted=formatSource source
    formatSource formatted `shouldBe` formatted
    let formattedLines=lines (S.content formatted)
    length (filter (== "end function") formattedLines) `shouldBe` 1
    length (filter ("law " `isPrefixOf`) formattedLines) `shouldBe` 5
    compileCoreCanonical 64 S.defaultGeneration [formatted] `shouldSatisfy` isRight
    let qualifiedUnit=S.Source "qualified.lawspec" (unlines
          ["unit example.of","type Switch is one of","| Off","| On","end type"])
        qualifiedFormatted=formatSource qualifiedUnit
    lines (S.content qualifiedFormatted) `shouldContain` ["  | Off","  | On"]
    compileCoreCanonical 64 S.defaultGeneration [qualifiedFormatted] `shouldSatisfy` isRight
  it "preserves record literals through serialization without sorting fields" $ do
    let literal=S.RecordLiteral [("z",S.IntLiteral 3),("a",S.BoolLiteral True)]
    (decode (encode literal) :: S.Literal) `shouldBe` literal
    S.literalExpr literal `shouldBe` S.RecordLit [("z",S.Number 3),("a",S.BoolLit True)]
  it "rejects duplicate fields, missing annotations and non-comma-separated values" $ do
    compile "function invalid (x of type record{n Integer}) -> Integer is 1 end function" `shouldSatisfy` isLeft
    forM_ ["record{n = 1, n = 2}","record{n = 1 enabled = true}"] $ \value ->
      compile ("law selected is definition: "++value++" = "++value++" end end") `shouldSatisfy` isLeft
