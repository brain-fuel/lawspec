-- | Ordered execution does not exempt discarded source branches from typing.
-- ref:DEC-total-definitions ref:DEC-typed-core-boundary
module SelectionAdmissionSpec (test_selectionAdmission) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.IORef
import Data.List (isInfixOf)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Core.Definitions (prepareHookedDefinitions)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Value (Value(..))
import LawSpec.Frontend (compileCoreCanonical)
import qualified LawSpec.Model as S
import LawSpec.Scalar (Scalar(..))
import SourceTupleSpec (checkOutcomes)

compile bits body = compileCoreCanonical bits S.defaultGeneration
  [S.Source "branches.lawspec" ("unit branches\n\n" ++ body ++ "\nend unit\n")]

accepts body = forM_ [32,64] $ \bits -> case compile bits body of
  Left diagnostics -> expectationFailure (show diagnostics)
  Right program -> validateProgram program `shouldBe` Right ()

rejects body = forM_ [32,64] $ \bits -> compile bits body `shouldSatisfy` isLeft

selected result rows = "function selected (value of type Bool) -> " ++ result ++
  " is first matching case of value: " ++ rows ++ " end case end function"

gadt = unlines
  [ "type Value (a of type Type) is one of"
  , "| Number of type record{value of type Integer} where a = Integer"
  , "| Truth of type record{value of type Bool} where a = Bool end type"
  ]

observe :: IORef [Integer] -> [Value] -> Either String Value
observe trace [value@(ScalarValue (SInteger _ n))] = unsafePerformIO $ do
  modifyIORef' trace (++ [n])
  pure (Right value)
observe _ _ = Left "invalid observed branch value"
{-# NOINLINE observe #-}

test_selectionAdmission = describe "independent admission of discarded case branches" $ do
  it "executes the branch-admission outcomes and emits every target at both widths" $ do
    content <- readFile "test/fixtures/canonical-branch-admission.lawspec"
    forM_ [32,64] $ \bits -> either (expectationFailure . show) checkOutcomes
      (compileCoreCanonical bits S.defaultGeneration [S.Source "admission.lawspec" content])
  it "rejects an unknown body name after an unconditional row in an unused definition" $
    rejects (selected "Bool" "when #any then true when true then absent")
  it "checks discarded result types against the selected expression's result" $ do
    rejects (selected "Bool" "when #any then true when true then 7")
    rejects (selected "Integer" "when true then 1 when false then 0 when true then false")
  it "requires Boolean guards even when prior rows cover the pattern" $ do
    rejects (selected "Bool" "when #any then true when true if 7 then false")
    rejects (selected "Bool" "when true then true when false then false when true if absent then false")
  it "checks a discarded otherwise without leaking names from earlier branches" $ do
    rejects (selected "Bool" "when true then true when false then false otherwise absent")
    rejects (selected "Bool" "when it matches bound then bound otherwise bound")
  it "retains contextual exact scalar types for discarded literals" $ do
    accepts (selected "UInt8" "when #any then 0 when true then 255 otherwise 7")
    rejects (selected "UInt8" "when #any then 0 when true then 256")
    rejects (selected "Integer" "when #any then 0 when true then 1.5")
  it "uses recursive product bindings in discarded guards and bodies without Eq" $ do
    let prefix = "function selected (value of type record{pair of type (Bool, Integer), item of type a}) -> Bool is first matching case of value: when #any then true "
        suffix = " end case end function"
    accepts (prefix ++ "when record{pair = (flag, number), item = ignored} if flag and number >= 0 then flag otherwise false" ++ suffix)
    rejects (prefix ++ "when record{pair = (flag, number)} if number then flag" ++ suffix)
  it "retains capabilities required by a discarded generic expression" $ do
    let body requirement = "function selected (value of type a) -> Bool " ++ requirement ++
          " is first matching case of value: when #any then true when it matches bound if bound = bound then true end case end function"
    rejects (body "")
    accepts (body "requires Eq a")
  it "retains constructor-local GADT equations in discarded rows" $ do
    let prefix = gadt ++ "function read (value of type Value a) -> a is first matching case of value: when Number record{value = n} then n when Truth record{value = b} then b "
        suffix = " end case end function"
    accepts (prefix ++ "when Number record{value = n} if n >= 0 then n when Truth record{value = b} if b then b" ++ suffix)
    rejects (prefix ++ "when Number record{value = n} then false" ++ suffix)
    rejects (prefix ++ "when Truth record{value = b} if 7 then b" ++ suffix)
  it "preserves the ordinary GADT rule for inaccessible constructors" $
    accepts (gadt ++ "function selected (value of type Value Bool) -> Bool is first matching case of value: when #any then true when Number record{value = n} if absent then absent end case end function")
  it "checks discarded guards and bodies in procedures and laws" $ do
    rejects "procedure selected (value of type Bool) -> Bool is first matching case of value: when #any then true when true if 7 then false end case end procedure\n"
    rejects "law requirement is definition: for all (value of type Bool) => first matching case of value: when #any then true when true then absent end case end for all end definition end law\n"
  it "retains nested selected-value scopes and removes temporary row names" $ do
    let body = selected "Bool" "when it matches bound then first matching case of (bound, 7): when (flag, number) then flag otherwise false end case otherwise false"
    forM_ [32,64] $ \bits -> case compile bits body of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> forM_ ["selection-row:","selection-branch-check:","selection-validation:","_lawspecUnreachableBranchResult_"] $ \marker ->
        show program `shouldSatisfy` (not . isInfixOf marker)
  it "keeps unreachable definedness and recursion out of the executable contract" $ do
    accepts (selected "Integer" "when #any then 0 when true then prelude.quot 1 0")
    accepts (selected "Integer" "when #any then 0 when true then selected value")
    rejects (selected "Integer" "when true then 0 when false then prelude.quot 1 0")
    rejects (selected "Integer" "when true then 0 when false then selected value")
  it "evaluates the subject once and never runs a discarded effectful body" $ do
    let body = unlines
          [ "ability Trace is mark :: Integer -> Integer end ability"
          , "procedure observed (ignored of type ()) -> Integer is"
          , "first matching case of mark 0: when #any then mark 1 when 0 then mark 2 otherwise mark 3 end case"
          , "end procedure" ]
    forM_ [32,64] $ \bits -> do
      program <- either (fail . show) pure (compile bits body)
      invoke <- either (fail . show) pure (prepareHookedDefinitions program)
      trace <- newIORef []
      let hook _ identity | C.idText identity == "branches::ability::Trace::mark" = Just (observe trace)
                          | otherwise = Nothing
          answer = invoke hook (C.Id "branches::observed") [ScalarValue (SAbsent "Unit")]
      _ <- evaluate (length (show answer))
      answer `shouldBe` Right (ScalarValue (SInteger "Integer" 1))
      readIORef trace `shouldReturn` [0,1]
