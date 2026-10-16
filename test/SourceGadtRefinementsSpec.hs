-- Stored structural restrictions remain obligations at construction and usable
-- facts when a GADT branch exposes the corresponding payload.
module SourceGadtRefinementsSpec (test_sourceGadtRefinements) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Common (Diagnostic(..))
import qualified LawSpec.Core as C
import qualified LawSpec.Model as S
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import qualified LawSpec.Core.Verification as V

compile body=compileCoreCanonical 64 S.defaultGeneration [S.Source "refined-indices.lawspec" ("unit refinedIndices\n"++body)]
checked result action=either (expectationFailure . show) action result
positive="record{value :: (n :: UInt8 where n > 0)}"
header="type Tagged (a :: Type) is one of | Tagged of type a where a = "++positive++" end type\n"
reciprocal argument pattern = "function reciprocal (tagged :: Tagged "++argument++") -> Rational is first matching case of tagged: "++pattern++" end case end function\n"
selected="law selected is definition: reciprocal (Tagged record{value = 2}) = (1 / 2) end end"
outcomes program=do
  validateProgram program `shouldBe` Right ()
  registry<-either fail pure (makeRegistry (C.programDataDeclarations program))
  invoke<-either (fail . show) pure (prepareDefinitions program)
  forM_ [property | owner<-C.programUnits program,property<-C.unitProperties owner,null (C.propertyInputs property)] $ \property ->
    evaluateValueProposition registry (C.programMachineBits program) invoke [] (C.propertyBody property) `shouldBe` Right True
  plan<-either (fail . show) pure (planTesting program)
  forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight

test_sourceGadtRefinements=describe "stored refinements in structural GADT indices" $ do
  it "uses a positive record field after a generic GADT payload pattern" $
    checked (compile (header++reciprocal "a" "when Tagged record{value = item} then 1 / item"++selected)) outcomes
  it "uses the same stored obligation through a generic payload projection" $
    checked (compile (header++reciprocal "a" "when Tagged payload then 1 / payload.value"++selected)) outcomes
  it "preserves an explicit refined structural index at a concrete match" $
    checked (compile (header++reciprocal positive "when Tagged payload then 1 / payload.value"++selected)) outcomes
  it "uses positive primitive domains and structural predicates for ordinary record arguments" $ do
    forM_ ["Nat","(n :: UInt8 where n > 0)"] $ \field ->
      checked (compile ("function reciprocal (record :: record{value :: "++field++"}) -> Rational is 1 / record.value end function\nlaw selected is definition: reciprocal record{value = 2} = (1 / 2) end end")) outcomes
  it "rejects a zero-inclusive denominator for the actual nonzero obligation" $ do
    let body="function invalid (record :: record{value :: UInt8}) -> Rational is 1 / record.value end function"
    case compile body of
      Left diagnostics -> diagnostics `shouldSatisfy` any (\diagnostic -> code diagnostic=="total" && "nonzero denominator" `isInfixOf` message diagnostic)
      Right _ -> expectationFailure "zero-inclusive exact division was accepted"
  it "rejects an invalid construction even when its GADT index supplies the payload type" $
    compile (header++"function invalid (ignored :: ()) -> Tagged "++positive++" is Tagged record{value = 0} end function") `shouldSatisfy` isLeft
  it "does not weaken a structural index or reuse another branch's field restrictions" $ do
    compile (header++reciprocal "record{value :: UInt8}" "when Tagged payload then 1 / payload.value") `shouldSatisfy` isLeft
    compile (unlines [
      "type Reading (a :: Type) is one of | Positive of type a where a = "++positive++" | Open of type a where a = record{value :: UInt8} end type",
      "function invalid (reading :: Reading a) -> Rational is first matching case of reading: when Positive payload then 1 / payload.value when Open payload then 1 / payload.value end case end function"]) `shouldSatisfy` isLeft
  it "uses dependent sibling restrictions through ordinary record projections" $
    checked (compile (unlines [
      "function reciprocal (span :: record{lower :: UInt8 upper :: (n :: UInt8 where n > lower)}) -> Rational is 1 / (span.upper - span.lower) end function",
      "law selected is definition: reciprocal record{lower = 2, upper = 4} = (1 / 2) end end"])) outcomes
  it "instantiates dependent field restrictions in a generic structural GADT payload" $
    checked (compile (unlines [
      "type Span (a :: Type) is one of | Span of type a where a = record{lower :: UInt8 upper :: (n :: UInt8 where n > lower)} end type",
      "function reciprocal (span :: Span a) -> Rational is first matching case of span: when Span payload then 1 / (payload.upper - payload.lower) end case end function",
      "law selected is definition: reciprocal (Span record{upper = 4, lower = 2}) = (1 / 2) end end"])) outcomes
  it "does not use a field restriction for a different record with the same field name" $
    compile ("function invalid (positive :: "++positive++") (open :: record{value :: UInt8}) -> Rational is 1 / open.value end function") `shouldSatisfy` isLeft
  it "rejects undefined construction and call inputs before using a projected restriction" $ do
    forM_ [
      "function invalid (ignored :: ()) -> Rational is let value = (record{value = 0} :: "++positive++") in 1 / value.value end function",
      "function invalid (ignored :: ()) -> Rational is let value = (record{value = 1 / 0} :: record{value :: Rational}) in 1 / value.value end function",
      "function supply (value :: Nat) -> record{value :: Nat} is record{value = value} end function\nfunction invalid (ignored :: ()) -> Rational is 1 / (supply 0).value end function"] $ \body ->
      compile body `shouldSatisfy` isLeft
  it "keeps zero-inclusive sibling dependencies insufficient for a nonzero denominator" $
    compile "function invalid (span :: record{lower :: UInt8 upper :: (n :: UInt8 where n >= lower)}) -> Rational is 1 / (span.upper - span.lower) end function" `shouldSatisfy` isLeft
  it "keeps full index descriptors distinct while normalizing admitted definitions idempotently" $
    checked (compile (header++reciprocal "a" "when Tagged payload then 1 / payload.value"++selected)) $ \program -> do
      outcomes program
      normalizeProgramRecords program `shouldBe` Right program
  it "checks positive readings and dependent intervals at both widths and emits all targets" $ do
    text <- readFile "test/fixtures/canonical-refined-gadt-indices.lawspec"
    forM_ [32,64] $ \bits -> checked
      (compileCoreCanonical bits S.defaultGeneration [S.Source "positive-readings.lawspec" text]) $ \program -> do
        let properties=[property | owner<-C.programUnits program,property<-C.unitProperties owner]
        length properties `shouldBe` 5
        sum [length (C.propertyExamples property) | property<-properties] `shouldBe` 12
        case dischargeEvidenceWith (V.Verification [V.Exhaustive,V.Examples]) program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right evidence -> [obligationStatus item | item<-evidence,obligationStage item=="law"] `shouldBe` replicate 5 ExhaustivelyChecked
        outcomes program
