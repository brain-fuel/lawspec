-- | Railway combinators over Either.
module RailwaySpec (test_railwayCombinatorsComposeResultsAsDocumented) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

source :: [String] -> Source
source = Source "railway.lawspec" . unlines . (header ++)
  where
    header =
      [ "unit example.railway"
      , "type Problem is | TooSmall | TooLarge end"
      , "definition positive (x :: BigInt) :: Either Problem BigInt is prelude.select (x > 0) (Right x) (Left TooSmall) end"
      , "definition small (x :: BigInt) :: Either Problem BigInt is prelude.select (x < 100) (Right x) (Left TooLarge) end"
      , "definition double (x :: BigInt) :: BigInt is x + x end"
      , "definition retry (p :: Problem) :: Either Problem BigInt is Right 1 end"
      , "definition describe (p :: Problem) :: Text is match p with | TooSmall -> \"small\" | TooLarge -> \"large\" end end"
      , "definition even (x :: BigInt) :: Bool is prelude.rem x 2 == 0 end" ]

-- | A law the compiler evaluates for both values of an unused input.
holds :: String -> String -> Expectation
holds left right = do
  let law = "law `l` is definition is `for all` (b :: Bool) . " ++ left ++ " = " ++ right ++ " end end"
  (compileCore 64 defaultGeneration [source [law]] >>= dischargeEvidence) `shouldSatisfy` isRight

refuted :: String -> String -> Expectation
refuted left right = do
  let law = "law `l` is definition is `for all` (b :: Bool) . " ++ left ++ " = " ++ right ++ " end end"
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
    holds "(positive (0 - 1) ?? (7 :: BigInt))" "7"
    holds "prelude.fromEither (7 :: BigInt) (positive 5)" "5"
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
