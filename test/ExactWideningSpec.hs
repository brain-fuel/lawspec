-- | Contextual scalar widening must preserve every source value, and must not
-- bypass nominal boundaries or mandatory definition admission.
-- ref:DEC-portable-exact-arithmetic ref:DEC-total-definitions
module ExactWideningSpec (test_exactWidening) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Test.Hspec
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTestingWith)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (obligationStage,obligationStatus,Status(..))
import qualified LawSpec.Core.Verification as V

test_exactWidening :: Spec
test_exactWidening = describe "compiler-proved exact scalar widening" $ forM_ [32,64] $ \bits -> do
  let compile body = compileCoreCanonical bits defaultGeneration [Source "widths.lawspec" ("unit widths\n\n" ++ body ++ "\nend unit\n")]
      function from to = "function wider (value :: " ++ from ++ ") -> " ++ to ++ " is value end function\n"
  it ("accepts complete range inclusions at " ++ show bits ++ " bits without selecting law verification") $
    forM_ [("Int8","Int16"),("UInt8","Int16"),("UInt8","UInt16"),("Int32","Int64"),
      ("UInt32","Int64"),("IntSize","Int64"),("UIntSize","Integer"),
      ("UInt8","Decimal"),("Int8","Rational"),("Decimal","Rational")] $ \(from,to) ->
        compile (function from to) `shouldSatisfy` isRight
  it ("rejects narrowing, signedness loss and inexact implicit conversions at " ++ show bits ++ " bits") $
    forM_ [("Int16","Int8"),("Int8","UInt16"),("UInt16","Int16"),("Int64","Int32"),
      ("UInt64","Int64"),("Integer","Int8"),("Rational","Decimal"),
      ("Float32","Float64"),("Float64","Float32"),("Integer","Float64")] $ \(from,to) ->
        compile (function from to) `shouldSatisfy` isLeft
  it ("retains nominal and closed-product boundaries at " ++ show bits ++ " bits") $ do
    compile ("wrapper Count is UInt8 end wrapper\n" ++ function "Count" "UInt16") `shouldSatisfy` isLeft
    compile "function wider (value :: record{count :: Int8}) -> record{count :: Int16} is value end function\n"
      `shouldSatisfy` isLeft
    compile "function unsafe (value :: Int8) -> Int16 is prelude.quot value 0 end function\n"
      `shouldSatisfy` isLeft
  it ("checks every UInt8 input and emits the checked conversion on all seventeen targets at " ++ show bits ++ " bits") $ do
    let source = function "UInt8" "Int16" ++ "\nlaw unchanged is definition: " ++
          "for all (value :: UInt8) => wider value must be prelude.Int16 value end for all end definition end law"
    case compile source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right evidence -> map obligationStatus (filter ((== "law") . obligationStage) evidence)
            `shouldBe` [ExhaustivelyChecked]
        case planTestingWith (V.Verification [V.Property,V.Examples]) program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
