-- | Eq-only collection algorithms use the existing checked definition engine.
module EqSetOperationsSpec (test_eqSetOperations) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Test.Hspec
import LawSpec.Collections (collectionsSource)
import LawSpec.Core (Id(..))
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Value (Value(..),listItems)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Testing (planTesting)

library = Source "<lawspec.collections>" (collectionsSource ["EqSet"])
compile bits text = compileCore bits defaultGeneration [library,Source "eq-set-operations.lawspec" text]

test_eqSetOperations = describe "Eq-only set checked operations" $ do
  it "checks ordinary definitions and their outcome laws at both widths through every emitter" $ do
    source <- readFile "test/fixtures/eq-set-operations.lawspec"
    forM_ [32,64] $ \bits -> case compile bits source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        dischargeEvidence program `shouldSatisfy` isRight
        case planTesting program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "retains the first zero's exact stored representation" $ do
    source <- readFile "test/fixtures/eq-set-operations.lawspec"
    case compile 64 source >>= prepareDefinitions of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right invoke -> forM_ [(False,"0000000000000000"),(True,"8000000000000000")] $ \(negative,bits) ->
        (invoke (Id "example.eq_sets::preservedZero") [ScalarValue (SBool negative)] >>= listItems)
          `shouldBe` Right [ScalarValue (SFloat "Float64" bits)]
  it "allows iteration without Eq and requires Eq to construct a set" $ do
    let prefix = "unit example.capabilities\nimport lawspec.collections as sets (EqSet)\n"
    compile 64 (prefix ++ "definition read (set :: EqSet (a -> a)) :: List (a -> a) is sets.eqSetItems set end") `shouldSatisfy` isRight
    compile 64 (prefix ++ "definition create (items :: List a) :: EqSet a is sets.eqSetOf items end") `shouldSatisfy` isLeft
