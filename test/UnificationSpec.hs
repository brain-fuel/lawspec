module UnificationSpec (spec) where

import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Unification

rowsOf :: FilePath -> IO [AbilityRow]
rowsOf path = do
  text <- readFile path
  case compileCore 64 defaultGeneration [Source path text] of
    Left diagnostics -> fail (show diagnostics)
    Right program -> pure (concatMap abilityRows (C.programUnits program))

usesOf :: String -> String -> [AbilityRow] -> [[String]]
usesOf construct name rows = [rowUses r | r <- rows, rowConstruct r == construct, rowName r == name]

spec :: Spec
spec = describe "existing features as abilities" $ do
  it "async adapters use Async" $ do
    rows <- rowsOf "examples/specs/async_fetch.lawspec"
    [rowUses r | r <- rows, rowConstruct r == "async"] `shouldSatisfy` (\us -> not (null us) && all (== [asyncAbility]) us)
  it "workflow policies use Async, Clock and Fail" $ do
    rows <- rowsOf "examples/specs/limits.lawspec"
    let stages = [rowUses r | r <- rows, rowConstruct r == "workflow stage"]
    stages `shouldSatisfy` any (elem "lawspec.time::ability::Clock")
    stages `shouldSatisfy` any (elem (builtinAbility "Fail(StageFailure)"))
    stages `shouldSatisfy` any (elem asyncAbility)
  it "protocols are Session abilities and mailboxes Mailbox abilities" $ do
    rows <- rowsOf "examples/specs/distribution.lawspec"
    usesOf "protocol" "Doubling" rows `shouldBe` [[builtinAbility "Session(Doubling)"]]
    usesOf "mailbox" "ledger" rows `shouldBe` [[builtinAbility "Mailbox(Int64)", "lawspec.time::ability::Clock"]]
  it "actors use Process with a State handler; models use State" $ do
    actors <- rowsOf "examples/specs/actors.lawspec"
    [rowUses r | r <- actors, rowConstruct r == "actor"] `shouldSatisfy` all (elem (builtinAbility "Process"))
    [rowConstruct r | r <- actors] `shouldSatisfy` elem "supervisor"
    models <- rowsOf "examples/specs/models.lawspec"
    [rowUses r | r <- models, rowConstruct r == "model"] `shouldSatisfy` all (any ((builtinAbility "State(") `isInfixOf`))
  it "scenarios run Session programs under the Scheduler" $ do
    rows <- rowsOf "examples/specs/models.lawspec"
    let scenarios = [rowUses r | r <- rows, rowConstruct r == "scenario"]
    scenarios `shouldSatisfy` (not . null)
    scenarios `shouldSatisfy` all (\us -> builtinAbility "Scheduler" `elem` us && builtinAbility "Process" `elem` us)
    scenarios `shouldSatisfy` any (any ((builtinAbility "Session(") `isInfixOf`))
