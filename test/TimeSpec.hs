-- | Durations: literals, operators and checked definitions.
module TimeSpec (test_durationsAreExactAndPortable) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Compile
import LawSpec.Model hiding (Expectation)
import LawSpec.Time (usesTime)

check :: [String] -> Either [Diagnostic] ([Unit], [Expanded])
check sources = compile [Source ("source" ++ show i ++ ".lawspec") s | (i, s) <- zip [0 :: Int ..] sources]

accepts :: String -> Expectation
accepts source = case check [source] of
  Left diagnostics -> expectationFailure (concatMap show diagnostics)
  Right _ -> pure ()

rejects :: String -> String -> Expectation
rejects fragment source = case check [source] of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

unit :: [String] -> String
unit body = unlines (["unit probe.time", ""] ++ body ++ ["end unit"])

bounded :: String -> String -> String
bounded domain body = unit ["function f (d :: Duration where " ++ domain ++ ") -> Duration is " ++ body ++ " end" ++ " function"]

-- | A duration means the same span on every target, so literals, operators and
-- their totality audit must be defined by LawSpec rather than each clock
-- library. ref:DEC-portable-exact-arithmetic ref:REQ-durations
test_durationsAreExactAndPortable :: Spec
test_durationsAreExactAndPortable = describe "durations" $ do
  describe "literals" $ do
    it "name units and equal their constructors" $
      accepts (unit [ "law \"|units| is definition : for all (b :: Bool) => (250ms = prelude.milliseconds 250 && 1min = 60s && 1d = 24h && 1000us = 1ms) = true end for all end definition end law" ])
    it "are bounded by about 146 years" $
      rejects "a duration is at most" (unit ["law big is definition: for all (b :: Bool) => (60000d = 1s) = true end for all end definition end law"])
    it "are found in source, but not in comments" $ do
      usesTime "x = 250ms" `shouldBe` True
      usesTime "-- 250ms\nx = 1" `shouldBe` False
      usesTime "wrapper Duration is Int64 end wrapper\nf :: Duration -> Bool\n" `shouldBe` False
  describe "operators" $ do
    it "add, subtract, scale, divide and compare" $
      accepts (unit [ "law \"|arithmetic| is definition : for all (b :: Bool) => (250ms + 750ms = 1s && 2s - 500ms = 1500ms && 3 * 1s = 3s && prelude.quot 1s 4 = 250ms && 1ms < 1s) = true end for all end definition end law" ])
    it "reject mixing durations and numbers in addition" $
      rejects "durations support" (unit [ "law \"|mixed| is definition : for all (b :: Bool) => (1s + 1 = 1s) = true end for all end definition end law" ])
  describe "in checked definitions" $ do
    it "prove each operation in range from a bound" $ do
      accepts (bounded "d <= 1s" "d + d")
      accepts (bounded "d <= 1s" "d + 1s")
      accepts (bounded "d <= 1s" "d * 2")
      accepts (bounded "d <= 1s" "prelude.quot d 2")
      accepts (bounded "d >= 1s" "d - 1s")
    it "reject an operation that can leave the range" $ do
      rejects "precondition could not be proved" (bounded "d <= 1s" "d - 1s")
      rejects "precondition could not be proved" (unit [ "function f (d :: Duration) -> Duration is d + d end function\n" ])
    it "scale a constant by a bounded count" $
      accepts (unit [ "function f (n :: Int32 where n >= 0 && n <= 5) -> Duration is 2s + 500ms * n end function\n" ])
  describe "the totality audit" $ do
    it "relates a product of a call to the call's named result" $
      accepts (unit [ "wrapper Small is Integer where value >= 0 && value <= 10 end wrapper"
                    , "function f (s :: Small) (k :: Integer where valueOfSmall s * k >= 0 && valueOfSmall s * k <= 10) -> Small is Small (valueOfSmall s * k) end function\n" ])
    it "bounds an integer quotient by its dividend" $
      accepts (unit [ "wrapper Small is Integer where value >= 0 && value <= 10 end wrapper"
                    , "function f (s :: Small) (k :: Integer where k > 0) -> Small is Small (prelude.quot (valueOfSmall s) k) end function\n" ])
    it "knows an unwrapped value satisfies its wrapper's constraint" $
      accepts (unit [ "wrapper Small is Integer where value >= 0 && value <= 10 end wrapper"
                    , "function f (s :: Small) -> Small is Small (valueOfSmall s) end function\n" ])
  it "import the time unit only where a source uses durations" $
    case check [unit ["f :: Duration -> Bool"], unlines [ "unit probe.other"
                                                         ++ "\n", ""
                                                        , ""
                                                        , "g :: Int32 -> Int32"
                                                        , "\nend unit" ]] of
      Left diagnostics -> expectationFailure (concatMap show diagnostics)
      Right (units, _) -> [unitName u | u <- units, any ((== "lawspecTimeDurationPlus") . functionName) (functionDefinitions u)]
        `shouldBe` ["probe.time"]
  it "unify the error type of a structural equation" $
    accepts (unlines [ "unit probe.equation"
                      ++ "\n", ""
                     , ""
                     , "type Problem is one of | TooSmall | Odd end type\n"
                     , "function positive (x :: Integer) -> Either Problem Integer is prelude.select (x > 0) (Right x) (Left TooSmall) end function\n"
                     , "function retry (p :: Problem) -> Either Problem Integer is Right 1 end function\n"
                     , "law \"|recovery| is definition : for all (x :: Integer) => (positive x <|> retry) = prelude.select (x > 0) (Right x) (Right 1) end for all end definition end law"
                     , "timeout :: Duration -> Bool"
                     , "\nend unit" ])
