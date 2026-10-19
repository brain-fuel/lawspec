-- | Railway combinators over Either.
module RailwaySpec (test_railwayCombinatorsComposeResultsAsDocumented) where

import FixtureSource (extendUnit)
import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

source :: [String] -> Source
source body = Source "railway.lawspec" (extendUnit (unlines header) (unlines body))
  where
    header =
      [ "unit example.railway\n\n\n"
      , ""
      , "type Problem is one of | TooSmall | TooLarge end type\n"
      , "function positive (x :: Integer) -> Either Problem Integer is prelude.select (x > 0) (Right x) (Left TooSmall) end function\n"
      , "function small (x :: Integer) -> Either Problem Integer is prelude.select (x < 100) (Right x) (Left TooLarge) end function\n"
      , "function double (x :: Integer) -> Integer is x + x end function\n"
      , "function retry (p :: Problem) -> Either Problem Integer is Right 1 end function\n"
      , "function describe (p :: Problem) -> Text is first matching case of p : when TooSmall then \"small\" when TooLarge then \"large\" end case end function\n"
      , "function even (x :: Integer) -> Bool is prelude.rem x 2 = 0 end function\n"
      , "\nend unit" ]

-- | A law the compiler evaluates for both values of an unused input.
holds :: String -> String -> Expectation
holds left right = do
  let law = "law \"|l| is definition: for all (b :: Bool) => " ++ left ++ " = " ++ right ++ " end for all end definition end law\n"
  (compileCore 64 defaultGeneration [source [law]] >>= dischargeEvidence) `shouldSatisfy` isRight

refuted :: String -> String -> Expectation
refuted left right = do
  let law = "law \"|l| is definition: for all (b :: Bool) => " ++ left ++ " = " ++ right ++ " end for all end definition end law\n"
  case compileCore 64 defaultGeneration [source [law]] >>= dischargeEvidence of
    Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "refuted"
    Right _ -> expectationFailure "expected the law to be refuted"

-- | Workflows chain fallible steps, so binding, mapping, recovery and pairing
-- must behave as the railway model says and bind with the documented
-- precedence. ref:DEC-domain-modeling-primitives ref:REQ-railway-combinators
test_railwayCombinatorsComposeResultsAsDocumented :: Spec
test_railwayCombinatorsComposeResultsAsDocumented = describe "railway combinators" $ do
  it "binds, maps and maps errors, as symbols and as prelude names" $ do
    holds "(positive 5 >>= small)" "prelude.bind (positive 5) small"
    holds "(double <$> positive 5)" "prelude.map double (positive 5)"
    holds "(describe <!> positive 5)" "prelude.mapError describe (positive 5)"
    holds "(positive 5 >>= small)" "(positive >=> small) 5"
    holds "(positive 5 >>= small)" "prelude.andThen positive small 5"
    holds "(5 |> double)" "double 5"
  it "recovers and falls back" $ do
    holds "(positive 5 <|> retry)" "prelude.orElse (positive 5) retry"
    holds "(positive (0 - 1) ?? (7 :: Integer))" "7"
    holds "prelude.fromEither (7 :: Integer) (positive 5)" "5"
    holds "prelude.isLeft (positive 5)" "!(prelude.isRight (positive 5))"
  it "ensures a predicate, failing with the given error" $ do
    holds "prelude.ensure even TooLarge (positive 4)" "positive 4"
    holds "prelude.ensure even TooLarge (positive 3)" "small 300"
  it "pairs two successes, keeping the first error" $ do
    holds "(positive 1 <*> small 2)" "Right (Pair 1 2)"
    holds "prelude.both (positive 0) (small 200)" "Left TooSmall"
  it "binds looser than arithmetic and tighter than comparisons" $ do
    holds "((positive 5 >>= small) == positive 5 >>= small)" "true"
    holds "(5 + 1 >= 5 - 1)" "true"
  it "is refuted when a law is wrong" $
    refuted "(positive 500 >>= small)" "positive 500"
