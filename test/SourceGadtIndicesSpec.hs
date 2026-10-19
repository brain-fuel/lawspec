-- Constructor equations apply to the same fresh indices in payloads and
-- results. They are local matching facts, never global type equalities.
module SourceGadtIndicesSpec (test_sourceGadtPayloadIndices) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Model as S
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import qualified LawSpec.Core.Verification as V
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)

compile body=compileCoreCanonical 64 S.defaultGeneration [S.Source "indices.lawspec" ("unit indices\n\n"++body ++ "\nend unit\n")]
declarations=unlines ["type Tagged (a :: Type) is one of",
  "| Tagged of type a where a = record{value :: Integer}","end type"]
checked result action=either (expectationFailure . show) action result
outcomes program = do
  validateProgram program `shouldBe` Right ()
  registry <- either fail pure (makeRegistry (C.programDataDeclarations program))
  invoke <- either (fail . show) pure (prepareDefinitions program)
  forM_ [property | unit<-C.programUnits program,property<-C.unitProperties unit,null (C.propertyInputs property)] $ \property ->
    evaluateValueProposition registry (C.programMachineBits program) invoke [] (C.propertyBody property) `shouldBe` Right True
  plan <- either (fail . show) pure (planTesting program)
  forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight

test_sourceGadtPayloadIndices=describe "source GADT payload indices" $ do
  it "uses an index's structural equation when matching its payload in a generic definition" $
    checked (compile (declarations++unlines [
      "function read (tagged :: Tagged a) -> Integer is",
      "first matching case of tagged: when Tagged record{value = item} then item end case end function",
      "law readValue is definition: read (Tagged record{value = 7}) = 7 end definition end law\n"])) outcomes
  it "applies fixed scalar equations while constructing and matching a payload" $
    checked (compile (unlines [ "type Fixed (a :: Type) is one of | Fixed of type a where a = UInt8 end type\n"
                              , "function read (fixed :: Fixed a) -> UInt8 is first matching case of fixed: when Fixed item then item end case end function"
                              , "law maximum is definition: read (Fixed 255) = (255 :: UInt8) end definition end law" ])) outcomes
  it "rejects a payload that disagrees with its constructor's fixed scalar index" $ do
    let header="type Fixed (a :: Type) is one of | Fixed of type a where a = UInt8 end type\n"
    forM_ ["true","256","-1"] $ \value ->
      compile (header++"function invalid (ignored :: ()) -> Fixed UInt8 is Fixed "++value++" end function") `shouldSatisfy` isLeft
  it "rejects wrong results in unused generic matches rather than constraining an unrelated payload variable" $
    compile (declarations++unlines [
      "function invalid (tagged :: Tagged a) -> Bool is",
      "first matching case of tagged: when Tagged item then item end case end function"]) `shouldSatisfy` isLeft
  it "keeps equations from separate constructors inside their own branches" $
    checked (compile (unlines [ "type Value (a :: Type) is one of | Number of type a where a = Integer | Truth of type a where a = Bool end type\n"
                              , "function unwrap (value :: Value a) -> a is first matching case of value:"
                              , "when Number item then item when Truth flag then flag end case end function"
                              , "law number is definition: unwrap (Number 7) = 7 end definition end law"
                              , "law truth is definition: unwrap (Truth true) = true end definition end law" ])) outcomes
  it "does not leak one branch's structural equation into an incompatible branch" $
    compile (unlines [
      "type Value (a :: Type) is one of | Number of type a where a = record{value :: Integer} | Truth of type a where a = Bool end type\n",
      "function invalid (value :: Value a) -> Integer is first matching case of value:",
      "when Number record{value = item} then item when Truth flag then flag.value end case end function"]) `shouldSatisfy` isLeft
  it "drops genuinely inaccessible constructors before checking their payload bodies" $
    checked (compile (unlines [ "type Value (a :: Type) is one of | Number of type a where a = Integer | Truth of type a where a = Bool end type\n"
                              , "function read (value :: Value Integer) -> Integer is first matching case of value:"
                              , "when Number item then item when Truth flag then unknown flag end case end function"
                              , "law number is definition: read (Number 7) = 7 end definition end law" ])) outcomes
  it "propagates equations between multiple indices into nested payload fields" $
    checked (compile (unlines [ "type Coupled (a :: Type) (b :: Type) is one of | Coupled of type record{first :: a second :: b} where a = List c, b = c end type\n"
                              , "function second (pair :: Coupled a b) -> b is first matching case of pair: when Coupled record{second = flag} then flag end case end function"
                              , "law selected is definition: second (Coupled record{first = [true, false], second = true}) = true end definition end law" ])) outcomes
  it "keeps normalization idempotent after structural index propagation" $
    checked (compile (declarations++unlines [
      "function read (tagged :: Tagged a) -> Integer is first matching case of tagged: when Tagged record{value = item} then item end case end function",
      "law readValue is definition: read (Tagged record{value = 7}) = 7 end definition end law\n"])) $ \program -> do
        let once=normalizeProgramRecords program
        once `shouldSatisfy` isRight
        (once >>= normalizeProgramRecords) `shouldBe` once

  it "matches concrete structural indices independently of their field order" $
    checked (compile (unlines [ "type Tagged (a :: Type) is one of | Tagged of type Bool where a = record{left :: UInt8 right :: Bool} end type\n"
                              , "function flag (tagged :: Tagged record{right :: Bool left :: UInt8}) -> Bool is first matching case of tagged:"
                              , "when Tagged enabled then enabled end case end function"
                              , "law selected is definition: flag (Tagged true) = true end definition end law" ])) outcomes
  it "does not erase intrinsic record restrictions to make an index match" $
    compile (unlines [
      "type Tagged (a :: Type) is one of | Tagged of type Bool where a = record{value :: (n :: UInt8 where n > 0)} end type\n",
      "function invalid (tagged :: Tagged record{value :: UInt8}) -> Bool is first matching case of tagged:",
      "when Tagged enabled then enabled end case end function"]) `shouldSatisfy` isLeft
  it "checks the indexed-reading demonstration exhaustively and emits all targets at both widths" $ do
    text <- readFile "test/fixtures/canonical-gadt-payload-indices.lawspec"
    forM_ [32,64] $ \bits -> checked
      (compileCoreCanonical bits S.defaultGeneration [S.Source "indexed-readings.lawspec" text]) $ \program -> do
        let properties=[property | unit<-C.programUnits program,property<-C.unitProperties unit]
        length properties `shouldBe` 4
        sum [length (C.propertyExamples property) | property<-properties] `shouldBe` 10
        case dischargeEvidenceWith (V.Verification [V.Exhaustive,V.Examples]) program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right evidence -> [obligationStatus item | item<-evidence,obligationStage item=="law"] `shouldBe` replicate 4 ExhaustivelyChecked
        outcomes program
