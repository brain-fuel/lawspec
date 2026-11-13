-- | Text that begins with a pipe, which the phrase-name delimiter shadows.
module PipeTextSpec (test_pipeTextIsDiagnosedWhereItIsWritten) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Compile
import LawSpec.Model hiding (Expectation)

check :: String -> Either [Diagnostic] ([Unit], [Expanded])
check source = compile [Source "source.lawspec" source]

unit :: [String] -> String
unit body = unlines (["unit probe.pipes", ""] ++ body ++ ["end unit"])

rejectsWithHint :: String -> Expectation
rejectsWithHint source = case check source of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "use triple quotes"
  Right _ -> expectationFailure "expected the pipe text to be refused"

accepts :: String -> Expectation
accepts source = case check source of
  Left diagnostics -> expectationFailure (concatMap show diagnostics)
  Right _ -> pure ()

-- | "| opens a phrase name, so "|" used to swallow the rest of its line and
-- fail at a later block. The author is told at the literal instead.
test_pipeTextIsDiagnosedWhereItIsWritten :: Spec
test_pipeTextIsDiagnosedWhereItIsWritten = describe "text that begins with a pipe" $ do
  it "is refused at a one-pipe literal, with the triple-quote spelling" $
    rejectsWithHint (unit
      [ "function row (label :: Text) -> Text is"
      , "  if label = \"\" then \"\" else \"|\" ++ label ++ \"|\" end if"
      , "end function" ])
  it "is refused when a phrase closes straight into a quote" $
    rejectsWithHint (unit ["function bar (unused :: Unit) -> Text is \"|x|\" end function"])
  it "is accepted in triple quotes" $
    accepts (unit
      [ "function row (label :: Text) -> Text is"
      , "  \"\"\"|\"\"\" ++ label ++ \"\"\"|\"\"\""
      , "end function" ])
  it "leaves phrase names that contain quotes alone" $
    accepts (unit
      [ "law \"|renders \"0\" for zero| is"
      , "  definition: prelude.textOf 0 = \"0\" end definition"
      , "end law" ])
