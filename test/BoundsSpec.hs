module BoundsSpec (spec) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Common
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Testing (planTesting)

-- A law over a data value and an integer refined to 1..1000: the
-- generators must draw the integer from that range.
purse :: String
purse = unlines
  [ "unit example.purse"
  , "type Purse is Purse coins :: Int64 end"
  , "definition spend (p :: Purse) (amount :: Int32 where amount >= 1 && amount <= 1000) :: Int32 is amount end"
  , "law `spending` is definition is `for all` (p :: Purse) (amount :: Int32 where amount >= 1 && amount <= 1000) . spend p amount >= 1 end end" ]

tests :: String -> Either [Diagnostic] String
tests target = do
  files <- compileCore 64 defaultGeneration [Source "purse.lawspec" purse] >>= planTesting >>= emitPlan target
  pure (concat [artifactContent f | f <- files, artifactPlacement f == "test"])

spec :: Spec
spec = describe "refinement bounds" $
  mapM_ (\(target, range) -> it ("narrow generation on " ++ target) $
    fmap (range `isInfixOf`) (tests target) `shouldBe` Right True)
    [ ("python", "st.integers(min_value=1, max_value=1000)")
    , ("javascript", "{min: 1n, max: 1000n}")
    , ("go", "Range(1, 1000)")
    , ("java", "integers(1, 1000)")
    , ("kotlin", "1..1000")
    , ("haskell", "(1) (1000)") ]
