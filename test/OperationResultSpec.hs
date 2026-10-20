-- | Abilities at refinement types. `uses Store Count` and
-- `handler ... for Store Count` elaborate through the alias, and a
-- definition may rely on an operation's refined result after a runtime
-- check where it calls the operation, which evidence reports as
-- runtime-checked.
module OperationResultSpec (test_operationResultsAreCheckedWhereTheyAreUsed) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..), programEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

program :: [String] -> Either [Diagnostic] C.Program
program body = compileCore 64 defaultGeneration
  [Source "operations.lawspec" (unlines (["unit gate5.operations", ""] ++ body ++ ["", "end unit"]))]

refusedWith :: String -> Either [Diagnostic] a -> Bool
refusedWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

store :: [String]
store =
  [ "refinement Count is (c :: Int32 where c >= 0) end refinement\n"
  , "ability Store (a :: Type) is"
  , "  load :: a"
  , "  save :: a -> Unit"
  , "end ability\n" ]

meter :: [String]
meter = ["ability Meter is reading :: (r :: Int32 where r >= 0) end ability\n"]

checks :: C.Program -> [Obligation]
checks compiled = [o | o <- programEvidence compiled, obligationStage o == "operation result"]

test_operationResultsAreCheckedWhereTheyAreUsed :: Spec
test_operationResultsAreCheckedWhereTheyAreUsed = describe "ability operations at refinement types" $ do
  describe "elaboration through a refinement alias" $ do
    it "elaborates uses Store Count" $
      program (store ++ ["procedure keep (n :: Count) -> Int32 uses Store Count is save n; load end procedure"])
        `shouldSatisfy` isRight
    it "elaborates a handler for Store Count" $
      program (store ++
        [ "handler countStore for Store Count with state count :: Count start 0 is"
        , "  operation load is count end operation"
        , "  operation save value is ~count := value; unitValue end operation"
        , "end handler" ])
        `shouldSatisfy` isRight
  describe "relying on a checked result" $ do
    it "proves a result refinement from the operation's refined result" $ do
      program (store ++ ["procedure keep (n :: Count) -> Count uses Store Count is save n; load end procedure"])
        `shouldSatisfy` isRight
      program (meter ++ ["procedure keep (u :: Unit) -> (r :: Int32 where r >= 0) uses Meter is reading end procedure"])
        `shouldSatisfy` isRight
    it "keeps the fact for a let-bound result" $ do
      program (["ability Pacer is step :: (r :: Int32 where r >= 1) end ability\n"] ++
        ["procedure share (total :: Int32) -> Int32 uses Pacer is let x = step in prelude.quot 100 x end let end procedure"])
        `shouldSatisfy` isRight
      program (["ability Pacer is step :: Int32 end ability\n"] ++
        ["procedure share (total :: Int32) -> Int32 uses Pacer is let x = step in prelude.quot 100 x end let end procedure"])
        `shouldSatisfy` refusedWith "nonzero denominator"
    it "still refuses a claim the refinement does not give" $ do
      program (meter ++ ["procedure keep (u :: Unit) -> (r :: Int32 where r >= 1) uses Meter is reading end procedure"])
        `shouldSatisfy` refusedWith "could not be proved"
      program (["ability Plain is reading :: Int32 end ability\n"] ++
        ["procedure keep (u :: Unit) -> (r :: Int32 where r >= 0) uses Plain is reading end procedure"])
        `shouldSatisfy` refusedWith "could not be proved"
    it "checks the result at each call and reports the check as runtime-checked" $ do
      compiled <- either (fail . show) pure
        (program (meter ++ ["procedure keep (u :: Unit) -> (r :: Int32 where r >= 0) uses Meter is reading end procedure"]))
      map obligationStatus (checks compiled) `shouldBe` [RuntimeChecked]
      map obligationReason (checks compiled) `shouldSatisfy` all ("checked on each result of reading" `isInfixOf`)
    it "adds no check where no operation result is refined" $ do
      compiled <- either (fail . show) pure
        (program (["ability Plain is reading :: Int32 end ability\n"] ++
          ["procedure keep (u :: Unit) -> Int32 uses Plain is reading end procedure"]))
      checks compiled `shouldBe` []
