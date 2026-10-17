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
    forM_
      [ ("anonymous", "record{message :: Text code :: Int8}", "record{message = \"negative amount\", code = 4}", "")
      , ("nominal", "Details", "Details record{message = \"negative amount\"}", "type Details is a record{message :: Text} end type")
      , ("generic nominal", "Details Text", "Details record{message = \"negative amount\"}", "type Details (a :: Type) is a record{message :: a} end type")
      ] $ \(name,payload,value,extra) ->
        it ("checks a Text message in an explicit " ++ name ++ " payload at " ++ show bits ++ " bits") $ do
          let body = unlines
                [ "unit failure", extra
                , "type Problem is one of | Declined of type " ++ payload ++ " | Blocked | Note of type Text | Count of type record{message :: Int8} end type"
                , "law outcome is definition:"
                , "  prelude.messageContains (Declined (" ++ value ++ ")) \"negative\""
                , "  and not (prelude.messageContains (Declined (" ++ value ++ ")) \"NEGATIVE\")"
                , "  and not (prelude.messageContains Blocked \"\")"
                , "  and not (prelude.messageContains (Note \"negative\") \"negative\")"
                , "  and not (prelude.messageContains (Count record{message = 4}) \"4\")"
                , "end end"
                ]
          program <- either (fail . show) pure (compileCoreCanonical bits defaultGeneration [Source "failure.lawspec" body])
          obligations <- either (fail . show) pure (dischargeEvidence program)
          map obligationStatus obligations `shouldSatisfy` all (`elem` [Proved,ExhaustivelyChecked])
    forM_ ["Text", "record{reason :: Text}", "record{message :: Int8}"] $ \payload ->
      it ("rejects a failure without a Text message field at " ++ show bits ++ " bits: " ++ payload) $ do
        let body = "unit failure\ntype Problem is one of | Declined of type " ++ payload ++ " end type\n" ++
              "law invalid is definition: for all (problem :: Problem) => prelude.messageContains problem \"negative\" end end end"
        compileCoreCanonical bits defaultGeneration [Source "failure.lawspec" body] `shouldSatisfy` isLeft
