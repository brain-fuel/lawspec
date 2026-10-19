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

library :: IO Source
library = Source "eq-set-operations-library.lawspec" <$> readFile "test/fixtures/eq-set-operations-library.lawspec"
compile builtins bits text = compileCore bits defaultGeneration [builtins,Source "eq-set-operations.lawspec" text]

test_eqSetOperations = describe "Eq-only set checked operations" $ do
  it "checks ordinary definitions and their outcome laws at both widths through every emitter" $ do
    builtins <- library
    source <- readFile "test/fixtures/eq-set-operations.lawspec"
    forM_ [32,64] $ \bits -> case compile builtins bits source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        dischargeEvidence program `shouldSatisfy` isRight
        case planTesting program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "retains the first zero's exact stored representation" $ do
    builtins <- library
    source <- readFile "test/fixtures/eq-set-operations.lawspec"
    case compile builtins 64 source >>= prepareDefinitions of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right invoke -> forM_ [(False,"0000000000000000"),(True,"8000000000000000")] $ \(negative,bits) ->
        (invoke (Id "example.eq_sets::preservedZero") [ScalarValue (SBool negative)] >>= listItems)
          `shouldBe` Right [ScalarValue (SFloat "Float64" bits)]
  it "allows iteration without Eq and requires Eq to construct a set" $ do
    builtins <- library
    let prefix = "unit example.capabilities\nimport example.eqSetAlgorithms as sets\n\n"
    compile builtins 64 (prefix ++ "function read (set :: Set (a -> a)) -> List (a -> a) is sets.eqSetItems set end function\nend unit") `shouldSatisfy` isRight
    compile builtins 64 (prefix ++ "function create (items :: List a) -> Set a is sets.eqSetOf items end function\nend unit") `shouldSatisfy` isLeft
