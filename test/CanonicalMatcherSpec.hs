module CanonicalMatcherSpec (test_canonicalMatchers) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Test.Hspec
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Core.Evidence (Obligation(..),Status(..))

source :: String -> String
source proposition = unlines
  [ "unit matcher"
  , "type Order is one of | Pending | Shipped of type record{id :: Int8 carrier :: Text} end type"
  , "law selected is definition: " ++ proposition ++ " end end"
  ]

test_canonicalMatchers :: Spec
test_canonicalMatchers = describe "canonical matchers" $ do
  forM_ [32,64] $ \bits -> do
    let compile body = compileCoreCanonical bits defaultGeneration [Source "matcher.lawspec" (source body)]
        verify body = do
          program <- either (fail . show) pure (compile body)
          obligations <- either (fail . show) pure (dischargeEvidence program)
          map obligationStatus obligations `shouldSatisfy` all (`elem` [Proved,ExhaustivelyChecked])
    it ("checks record payloads and omitted fields at " ++ show bits ++ " bits") $ do
      verify "Shipped record{id = 1, carrier = \"post\"} matches Shipped record{carrier = \"post\"}"
      verify "not (Pending matches Shipped record{})"
      verify "not (Shipped record{id = 1, carrier = \"post\"} matches Shipped record{id = 2})"
    it ("checks recursive, tuple and wildcard patterns at " ++ show bits ++ " bits") $ do
      verify "[Just (1, true)] matches Cons (Just (1, #any)) Nil"
      verify "not ([Just (1, true)] matches Cons (Just (2, _)) Nil)"
      verify "record{answer = true, count = 1} matches record{answer = true}"
    it ("preserves literal and regular expression matching at " ++ show bits ++ " bits") $ do
      verify "true matches true"
      verify "\"post\" matches regex \"[a-z]+\""
      verify "let pattern = regex \"[a-z]+\" in \"post\" matches pattern"
    forM_
      [ "Shipped record{id = 1, carrier = \"post\"} matches Shipped record{unknown = _}"
      , "Shipped record{id = 1, carrier = \"post\"} matches Shipped record{id = _, id = _}"
      , "Shipped record{id = 1, carrier = \"post\"} matches Shipped record{id = same, carrier = same}"
      , "Shipped record{id = 1, carrier = \"post\"} matches Shipped (_, _)"
      ] $ \body -> it ("rejects an invalid pattern at " ++ show bits ++ " bits: " ++ body) $
        compile body `shouldSatisfy` isLeft
