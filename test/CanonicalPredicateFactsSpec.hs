-- | Canonical cases in input predicates retain their constructor facts during
-- mandatory definition admission, independently of optional law verification.
module CanonicalPredicateFactsSpec (test_canonicalPredicateFacts) where

import Control.Monad (forM_)
import Data.Either (isRight)
import Test.Hspec
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Model (Source(..),Diagnostic,defaultGeneration,code)
import LawSpec.Core (Program)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Types as Types
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition)
import Data.List (isPrefixOf)

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
    it ("proves generic indexed concatenation at " ++ show bits ++ " bits") $
      check bits (vectorSource "VCons record{head = h, tail = concatV t ys}") `shouldSatisfy` isRight
    forM_
      [ "concatV t ys"
      , "VCons record{head = h, tail = ys}"
      , "VCons record{head = prelude.quot h 0, tail = concatV t ys}"
      , "concatV xs ys"
      ] $ \result -> it ("rejects an invalid indexed result or recursion at " ++ show bits ++ " bits: " ++ result) $
        case check bits (vectorSource result) of
          Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
          Right _ -> expectationFailure "invalid indexed definition admitted"
    it ("agrees with independent finite concatenation outcomes at " ++ show bits ++ " bits") $ do
      let inputs=concat [sequence (replicate size [0::Int,1]) | size<-[0..2]]
          vector []="VNil"
          vector (head:tail)="(VCons record{head = "++show head++", tail = "++vector tail++"})"
          laws=["law matrix"++show index++" is definition: concatV "++vector left++" "++vector right++
            " must be "++vector (left++right)++" end end" | (index,(left,right))<-zip [0::Int ..] [(l,r) | l<-inputs,r<-inputs]]
      program<-either (fail . show) pure (check bits (vectorSource "VCons record{head = h, tail = concatV t ys}"++unlines laws))
      registry<-either fail pure (Types.makeRegistry (C.programDataDeclarations program))
      invoke<-either (fail . show) pure (prepareDefinitions program)
      let properties=[p | unit<-C.programUnits program,p<-C.unitProperties unit,"matrix" `isPrefixOf` C.propertyName p]
      length properties `shouldBe` 49
      forM_ properties $ \property -> evaluateValueProposition registry bits invoke [] (C.propertyBody property) `shouldBe` Right True
    it ("does not establish IEEE reflexivity through a product projection at " ++ show bits ++ " bits") $
      case check bits (unlines
        ["unit predicateFacts"
        ,"function pack (value :: a) -> record{field :: a} is record{field = value} end function"
        ,"function reflect (value :: record{field :: Float64}) -> (result :: Float64 where result = value.field) is value.field end function"]) of
        Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
        Right _ -> expectationFailure "IEEE reflexivity admitted"
    it ("rejects a different, identically zero denominator at " ++ show bits ++ " bits") $
      case check bits (rangeSource ">" "lo - lo") of
        Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
        Right _ -> expectationFailure "zero divisor admitted"

vectorSource :: String -> String
vectorSource result = unlines
  [ "unit predicateFacts"
  , "type Vec (n :: Whole) (a :: Type) is one of"
  , "  | VNil where n = 0"
  , "  | VCons of type record{head :: a tail :: Vec m a} where n = m + 1"
  , "end type"
  , "function concatV (xs :: Vec n Int8) (ys :: Vec m Int8) -> Vec (n + m) Int8 is"
  , "  first matching case of xs:"
  , "    when VNil then ys"
  , "    when VCons record{head = h, tail = t} then " ++ result
  , "  end case"
  , "end function"
  ]
