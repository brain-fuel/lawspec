-- | Z3's model of a negated task is checked by the reference evaluator before
-- it is called a counterexample. These tests give the values directly, as
-- the host passes Z3's get-value answer, so they need no solver; the npm
-- tests run the same path with Z3.
module CounterexampleSpec (test_counterexamplesAreConfirmedByTheEvaluator) where

import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Api as API
import qualified LawSpec.Core.Smt as SMT
import LawSpec.Core.Counterexample (CounterexampleCheck(..), checkStatus, validateCounterexample)
import LawSpec.Frontend (compileCoreCanonical)
import qualified LawSpec.Model as S

law :: String -> String
law text = "law selected is definition: " ++ text ++ " end definition end law\n"

checked :: String -> String -> IO CounterexampleCheck
checked body answer = do
  program <- either (fail . show) pure (compileCoreCanonical 64 S.defaultGeneration
    [S.Source "cx.lawspec" ("unit cx\n\n" ++ body ++ "\nend unit\n")])
  tasks <- either (fail . show) pure (SMT.proofTasks program)
  case tasks of
    [task] -> pure (validateCounterexample program task answer)
    _ -> fail "expected one task"

status :: CounterexampleCheck -> String
status = checkStatus

test_counterexamplesAreConfirmedByTheEvaluator :: Spec
test_counterexamplesAreConfirmedByTheEvaluator = describe "validated counterexamples" $ do
  it "refutes a false law at the values Z3 gave" $ do
    result <- checked (law "for all (n :: Integer) => n = n + 1 end for all") "((lawspec_input_0 0))"
    status result `shouldBe` "refuted"
    result `shouldSatisfy` \r -> case r of Refuted [_] _ -> True; _ -> False
  it "reads negative integers" $
    (status <$> checked (law "for all (n :: Integer) => n >= 0 end for all") "((lawspec_input_0 (- 3)))")
      `shouldReturn` "refuted"
  it "reports a law undefined at the values as refuted" $ do
    result <- checked (law "for all (n :: Integer) => 1 / n = 1 / n end for all") "((lawspec_input_0 0))"
    status result `shouldBe` "refuted"
    result `shouldSatisfy` \r -> case r of Refuted _ why -> "undefined" `isInfixOf` why; _ -> False
  it "does not confirm values at which the law holds, as a broken translation would give" $
    (status <$> checked (law "for all (n :: Integer) => n * n >= 0 end for all") "((lawspec_input_0 3))")
      `shouldReturn` "model-not-confirmed"
  it "does not confirm values outside the type or the law's domain" $ do
    (status <$> checked (law "for all (n :: Int8) => n < 100 end for all") "((lawspec_input_0 300))")
      `shouldReturn` "model-not-confirmed"
    (status <$> checked (law "for all (n :: Int8 where n > 3) => n < 100 end for all") "((lawspec_input_0 1))")
      `shouldReturn` "model-not-confirmed"
  it "searches inner quantifiers over finite domains completely" $
    (status <$> checked (law "for all (x :: Int8 where x >= 0 and x <= 5) => there exists (y :: Int8 where y >= 0 and y <= 5) such that y > x end exists end for all")
      "((lawspec_input_0 5))") `shouldReturn` "refuted"
  it "leaves values unconfirmed when an inner quantifier cannot be searched" $
    (status <$> checked (law "for all (x :: Integer) => there exists (y :: Integer) such that y > x end exists end for all")
      "((lawspec_input_0 5))") `shouldReturn` "incomplete"
  it "decides a closed law with no inputs" $
    (status <$> checked (law "1 + 1 = 3") "()") `shouldReturn` "refuted"
  it "refuses an answer it cannot read" $
    (status <$> checked (law "for all (n :: Integer) => n = n + 1 end for all") "((lawspec_input_0 (root-obj x 1)))")
      `shouldReturn` "incomplete"
  it "checks values only against a task the compiler itself prepared" $ do
    let request extra = object ([ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String)
          , "method" .= ("proofTasks" :: String), "verification" .= object ["layers" .= ["proof" :: String]]
          , "sources" .= [object ["path" .= ("cx.lawspec" :: String), "content" .= ("unit cx\n\n" ++ law "for all (n :: Integer) => n = n + 1 end for all" ++ "end unit\n")]]] ++ extra)
        ask extra = decode (API.dispatch (encode (request extra))) :: Maybe Value
    Just (Object prepared) <- pure (ask [])
    Just (Array tasks) <- pure (K.lookup "proofTasks" prepared)
    Object task : _ <- pure (toList tasks)
    Just (Object query) <- pure (K.lookup "counterexample" task)
    K.lookup "encoding" query `shouldBe` Just (String "lawspec-smtlib-v2")
    K.lookup "encoding" task `shouldBe` Just (String "lawspec-smtlib-v1")
    let cx fingerprint = ["proofCounterexamples" .= [object ["owner" .= K.lookup "owner" task, "declaration" .= K.lookup "declaration" task,
          "taskFingerprint" .= fingerprint, "values" .= ("((lawspec_input_0 7))" :: String)]]]
        statusOf fingerprint = case ask (cx fingerprint) of
          Just (Object response) | Just (Array rows) <- K.lookup "counterexampleChecks" response, [Object row] <- toList rows -> K.lookup "status" row
          _ -> Nothing
    statusOf (K.lookup "taskFingerprint" task) `shouldBe` Just (String "refuted")
    statusOf (Just (String "0000")) `shouldBe` Just (String "incomplete")
