-- Complete covers must agree with independent range and restriction oracles;
-- incomplete covers must never establish absence. ref:DEC-evidence-statuses
module QuantifierDomainSpec (test_refinedIntegerDomainsAreComplete) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import qualified LawSpec.Core.Verification as V
import LawSpec.Testing
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Core.QuantifierDomain (finiteQuantifierTerms)
import LawSpec.Core.Value (Value(..))
import LawSpec.Core.Eval (evaluateValue)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Scalar (Scalar(..))

compile :: String -> Either [Diagnostic] C.Program
compile body = compileCoreCanonical 64 defaultGeneration [Source "ranges.lawspec" ("unit example.ranges\n\n" ++ body ++ "\nend unit\n")]

law :: String -> String
law claim = "law selected is definition: " ++ claim ++ " end definition end law\n"

checked :: Either [Diagnostic] C.Program -> (C.Program -> Expectation) -> Expectation
checked value body = either (expectationFailure . show) body value

statuses :: [V.Layer] -> C.Program -> Either [Diagnostic] [Status]
statuses layers program = map obligationStatus . filter ((== "law") . obligationStage) <$>
  dischargeEvidenceWith (V.Verification layers) program

test_refinedIntegerDomainsAreComplete :: Spec
test_refinedIntegerDomainsAreComplete = describe "complete refined integer domains" $ do
  it "checks existence and absence over constant ranges without a configured witness" $ do
    let claims = ["there exists (value :: Integer where value >= -2 and value < 3) such that value = 2 end exists",
          "there does not exist (value :: Integer where value >= -2 and value < 3) such that value = 3 end exists"]
    mapM_ (\claim -> checked (compile (law claim)) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]) claims
  it "checks every admitted outer tuple, including dependent integer inputs" $
    checked (compile (law "for all (base :: Integer where base >= 0 and base <= 2) (next :: Integer where next >= base and next <= base + 2) => next >= base end for all")) $ \program -> do
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
      case planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> [finiteCases p | u <- plannedUnits plan,p <- plannedProperties u] `shouldBe`
          [Just [[ScalarValue (SInteger "Integer" base),ScalarValue (SInteger "Integer" next)] |
            base <- [0..2],next <- [base..base+2]]]
  it "preserves positive and zero-inclusive numeric domains" $ do
    let claims = ["there does not exist (value :: Nat where value <= 3) such that value = 0 end exists",
          "there exists (value :: Whole where value <= 3) such that value = 0 end exists"]
    mapM_ (\claim -> checked (compile (law claim)) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]) claims
  it "intersects finite-width bounds before constructing contextual constants" $ do
    let claims = ["there does not exist (value :: UInt8 where value + 0 = 300) such that true end exists",
          "there does not exist (value :: Whole where value + 0 = -1) such that true end exists",
          "there exists (value :: Int8 where value + 0 >= 126 and value + 0 <= 300) such that value = 127 end exists"]
    mapM_ (\claim -> checked (compile (law claim)) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]) claims
  it "handles reversed comparisons, exact affine arithmetic and additional filters" $ do
    let claims = ["there exists (value :: Integer where -2 < value and 3 >= value and value != 0) such that value = 3 end exists",
          "there exists (value :: Integer where value + 2 >= 0 and 5 >= value + 2) such that value = -2 end exists",
          "there does not exist (value :: Integer where value >= 0 and value <= 3 and value != 2) such that value = 2 end exists"]
    mapM_ (\claim -> checked (compile (law claim)) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]) claims
  it "recognizes a contradictory dependent interval before an unreachable infinite search" $
    checked (compile (law "for all (base :: Integer) (value :: Integer where value > base and value < base + 1) => there exists (answer :: Integer) such that false end exists end for all")) $ \program -> do
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
      case planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> [finiteCases p | u <- plannedUnits plan,p <- plannedProperties u] `shouldBe` [Just []]
  it "checks a fixed-width interval nested below an unbounded universal" $
    checked (compile (law "for all (base :: Integer) => there exists (next :: Integer where next > base and next <= base + 3) such that next = base + 2 end exists end for all")) $ \program -> do
      statuses [V.Proof] program `shouldBe` Right [Proved]
      case planTestingWith (V.Verification [V.Property]) program of
        Left ds -> expectationFailure (show ds)
        Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "keeps rational, nonlinear, disjunctive and one-sided searches incomplete" $ do
    let claims = ["there exists (value :: Rational where value >= 0 and value <= 1) such that value = 2 end exists",
          "there exists (value :: Integer where value * value <= 4) such that value * value = -1 end exists",
          "there must not exist (value :: Integer where (value >= 0 and value <= 3) or value = 99999) such that value * value = -1 end exists",
          "there does not exist (value :: Integer where value >= 0) such that value * value = -1 end exists"]
    mapM_ (\claim -> checked (compile (law claim)) $ \program -> do
      statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
      planTestingWith (V.Verification [V.Exhaustive]) program `shouldSatisfy` isRight) claims
  it "preserves incomplete status when the complete interval exceeds the expansion limit" $
    checked (compile (law "there does not exist (value :: Integer where value >= 0 and value <= 3) such that value * value = -1 end exists")) $ \program -> do
      let small = program { C.programUnits = [u { C.unitProperties =
            [p { C.propertyGeneration = defaultGeneration { exhaustiveLimit = 2 } } | p <- C.unitProperties u] }
            | u <- C.programUnits program] }
      statuses [V.Exhaustive] small `shouldBe` Right [Incomplete]
  it "retains a real refutation at a range endpoint" $
    checked (compile (law "for all (value :: Integer where value >= -2 and value <= 3) => value < 3 end for all")) $ \program ->
      case statuses [V.Exhaustive] program of
        Left ds -> map code ds `shouldBe` ["refuted"]
        Right value -> expectationFailure (show value)
  it "agrees with independent accepted-value oracles for intersected and translated covers" $ do
    let integer = C.scalarType "Integer"
        origin = C.GeneratedFrom (C.Id "domain-oracle")
        binder = C.Binder (C.Id "value") "value" integer
        local n = C.Expr integer (C.Local (C.Id n)) origin
        constant n = C.Expr integer (C.Constant (SInteger "Integer" n)) origin
        operation op a b = C.Expr (if op `elem` [C.Add,C.Subtract,C.Multiply] then integer else C.scalarType "Bool")
          (C.Binary op (C.Numeric integer) a b) origin
        invoke _ _ = Left "the domain oracle calls no functions"
    case makeRegistry [] of
      Left message -> expectationFailure message
      Right registry -> mapM_ (\(base,lo,hi) -> do
        let q = C.Quantifier binder
              [operation C.GreaterEqual (operation C.Subtract (local "value") (local "base")) (constant lo),
               operation C.LessEqual (local "value") (operation C.Add (local "base") (constant hi))] []
            actual = do
              cover <- finiteQuantifierTerms 64 20 (const (Right Nothing)) q
              traverse (mapM (evaluateValue registry 64 invoke [(C.Id "base",ScalarValue (SInteger "Integer" base))])) cover
        actual `shouldBe` Right (Just [ScalarValue (SInteger "Integer" value) |
          value <- [base-5..base+5],value-base >= lo,value <= base+hi]))
        [(base,lo,hi) | base <- [-100,0,100],lo <- [-2..2],hi <- [-2..2]]
  it "leaves intrinsic definition validation and unselected law verification in place" $ do
    checked (compile (law "for all (value :: Integer where value >= 0 and value <= 3) => value < 3 end for all")) $ \program ->
      statuses [] program `shouldBe` Right [NotVerified]
    compile ("function loop (value :: Integer) -> Integer is loop value end function\n" ++ law "true")
      `shouldSatisfy` either (any ((== "total") . code)) (const False)
  it "checks the finite-domain settlement demonstration through every target" $ do
    let path = "examples/rc1/finite-integer-domains.lawspec"
    source <- readFile path
    checked (compileCoreCanonical 64 defaultGeneration [Source path source]) $ \program -> do
      case statuses [V.Proof,V.Exhaustive] program of
        Left ds -> expectationFailure (show ds)
        Right evidence -> do
          length evidence `shouldBe` 6
          evidence `shouldSatisfy` all (`elem` [Proved,ExhaustivelyChecked])
      case planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
