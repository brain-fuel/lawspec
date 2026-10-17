-- | Canonical cases in input predicates retain their constructor facts during
-- mandatory definition admission, independently of optional law verification.
module CanonicalPredicateFactsSpec (test_canonicalPredicateFacts) where

import Control.Monad (forM_)
import Data.Either (isRight)
import Test.Hspec
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Model (Source(..),Diagnostic,defaultGeneration,code)
import LawSpec.Core (Program)

rangeSource :: String -> String -> String
rangeSource comparison denominator = unlines
  [ "unit predicateFacts"
  , "type Range is a record{lower :: Int8 upper :: Int8} end type"
  , "function gap (range :: Range where first matching case of range:"
  , "  when Range record{lower = lo, upper = hi} then hi " ++ comparison ++ " lo"
  , "end case) -> Rational is"
  , "  first matching case of range:"
  , "    when Range record{lower = lo, upper = hi} then 1 / (" ++ denominator ++ ")"
  , "  end case"
  , "end function"
  ]

check :: Int -> String -> Either [Diagnostic] Program
check bits body = compileCoreCanonical bits defaultGeneration [Source "predicate-facts.lawspec" body]

test_canonicalPredicateFacts :: Spec
test_canonicalPredicateFacts = describe "canonical predicate facts" $ do
  forM_ [32,64] $ \bits -> do
    it ("retains strict case predicates for exact division at " ++ show bits ++ " bits") $
      check bits (rangeSource ">" "hi - lo") `shouldSatisfy` isRight
    it ("rejects a zero-inclusive predicate at " ++ show bits ++ " bits") $
      case check bits (rangeSource ">=" "hi - lo") of
        Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
        Right _ -> expectationFailure "zero divisor admitted"
    it ("rejects a different, identically zero denominator at " ++ show bits ++ " bits") $
      case check bits (rangeSource ">" "lo - lo") of
        Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
        Right _ -> expectationFailure "zero divisor admitted"
