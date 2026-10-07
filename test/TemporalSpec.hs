-- | Temporal propositions and performance budgets.
module TemporalSpec (test_temporalPropositionsAndBudgetsAreCheckedOverTheClock) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Testing (planTesting)

program :: String -> Either [Diagnostic] C.Program
program text = compileCore 64 defaultGeneration [Source "app.lawspec" text]

discharged :: String -> Either [Diagnostic] [Obligation]
discharged text = program text >>= dischargeEvidence

source :: [String] -> String
source rest = unlines ("unit app.temporal" : "" : "import lawspec.time (Instant)" : rest)

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

statusOf :: String -> C.Program -> [Status]
statusOf law compiled =
  [ obligationStatus o | Right os <- [dischargeEvidence compiled], o <- os, obligationStage o == "law"
  , law `isInfixOf` C.idText (obligationDeclaration o) ]

handlersOf :: String -> C.Program -> [[(String, C.HandlerRef)]]
handlersOf law compiled =
  [ [(C.abilityKey a, h) | (a, h) <- C.propertyHandlers p]
  | u <- C.programUnits compiled, p <- C.unitProperties u, law `isInfixOf` C.propertyName p ]

targets :: [String]
targets = ["python", "javascript", "typescript", "go", "java", "kotlin", "haskell", "rust"]

-- | Time in laws must be checked over the Clock ability, so that a virtual clock
-- makes it deterministic and a budget is reported as measured, never proved. ref:REQ-temporal-propositions
test_temporalPropositionsAndBudgetsAreCheckedOverTheClock :: Spec
test_temporalPropositionsAndBudgetsAreCheckedOverTheClock = describe "temporal propositions and budgets" $ do
  let deadline =
        [ "definition deadline (wait :: Duration where wait <= 1h) :: Instant uses Clock is now + wait end" ]
      eventually = deadline ++
        [ "law `a deadline passes` using virtual clock is"
        , "  definition is (let d = deadline 1s in eventually within 2 s, now >= d) = true end"
        , "end" ]
  describe "eventually, always and never" $ do
    it "compile under the virtual clock, deterministically" $
      program (source eventually) `shouldSatisfy` isRight
    it "are checked by the compiler under the virtual clock" $ do
      let Right compiled = program (source eventually)
      statusOf "a deadline passes" compiled `shouldSatisfy` all (`elem` [Proved, ExhaustivelyChecked])
    it "refute a false proposition at compile time" $
      discharged (source (deadline ++
        [ "law `too soon` using virtual clock is"
        , "  definition is (let d = deadline 3s in eventually within 2 s, now >= d) = true end"
        , "end" ])) `shouldSatisfy` failsWith "too soon"
    it "hold always and never over the whole span" $
      program (source (deadline ++
        [ "law `before the deadline` using virtual clock is"
        , "  definition is (let d = deadline 3s in always within 2s, now < d) = true end"
        , "end"
        , "law `never past it` using virtual clock is"
        , "  definition is (let d = deadline 3s in never within 2 s, now >= d) = true end"
        , "end" ])) `shouldSatisfy` isRight
    it "reject an always that fails part way" $
      discharged (source (deadline ++
        [ "law `not for long` using virtual clock is"
        , "  definition is (let d = deadline 1s in always within 2 s, now < d) = true end"
        , "end" ])) `shouldSatisfy` failsWith "not for long"
    it "use the clock, so they need lawspec.time" $
      program (unlines ["unit app.untimed", "law `x` is definition is (eventually within 1s, true) = true end end"])
        `shouldSatisfy` either (const True) (const False)

  describe "budgets" $ do
    let budget =
          [ "definition double (n :: Int32) :: Int64 is n * 2 end"
          , "law `doubling is quick` is"
          , "  definition is `for all` (n :: Int32) . double n takes at most 5 ms end"
          , "  example `one` is"
          , "    n = 1"
          , "    expect double n takes at most 5ms"
          , "  end"
          , "end" ]
    it "run on the real clock only, and are measured" $ do
      let Right compiled = program (source budget)
      statusOf "doubling is quick" compiled `shouldBe` [Measured]
      handlersOf "doubling is quick" compiled `shouldBe` [[("lawspec.time::ability::Clock", C.ProductionHandler)]]
    it "may not name another clock" $
      program (source
        [ "definition double (n :: Int32) :: Int64 is n * 2 end"
        , "law `virtual budget` using virtual clock is"
        , "  definition is `for all` (n :: Int32) . double n takes at most 5 ms end"
        , "end" ]) `shouldSatisfy` failsWith "measured on the real clock"
    it "generate on every target" $
      mapM_ (\t -> (program (source budget) >>= planTesting >>= emitPlan t) `shouldSatisfy` isRight) targets
