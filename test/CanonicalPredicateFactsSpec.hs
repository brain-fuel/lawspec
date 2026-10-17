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
    forM_ ["Nat", "(positive :: UInt8 where positive > 0)"] $ \element ->
      it ("retains refined element contracts through indexed concatenation at " ++ show bits ++ " bits: " ++ element) $
        check bits (vectorSourceFor element "VCons record{head = h, tail = concatV t ys}") `shouldSatisfy` isRight
    it ("retains a positive stored head at " ++ show bits ++ " bits") $
      check bits (headSource "Nat" "h") `shouldSatisfy` isRight
    forM_
      [(headSource "Whole" "h", "unrestricted head")
      ,(headSource "Nat" "h - 1", "weakened positive head")
      ,(headSource "Nat" "prelude.quot h (h - h)", "strict zero divisor")
      ,(vectorHeader ++ "function other (xs :: Vec n Nat) (unrelated :: Whole) -> Nat is first matching case of xs: when VNil then 1 when VCons record{head = h} then unrelated end case end function", "unrelated argument")
      ,(pairSource "second", "different parameter position")
      ,(nestedSource "Whole", "unrestricted nested field")
      ] $ \(source,label) -> it ("keeps payload facts scoped at " ++ show bits ++ " bits: " ++ label) $
        case check bits source of
          Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
          Right _ -> expectationFailure ("invalid payload contract admitted: " ++ label)
    it ("follows the right parameter through reordered record fields at " ++ show bits ++ " bits") $
      check bits (pairSource "first") `shouldSatisfy` isRight
    it ("follows nested record projections at " ++ show bits ++ " bits") $
      check bits (nestedSource "Nat") `shouldSatisfy` isRight
    it ("retains list element refinements through a stored field at " ++ show bits ++ " bits") $
      check bits listSource `shouldSatisfy` isRight
    it ("does not strengthen unrestricted stored list elements at " ++ show bits ++ " bits") $
      case check bits (listSourceFor "Whole") of
        Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
        Right _ -> expectationFailure "unrestricted list elements became positive"
    it ("retains Boolean payload restrictions at " ++ show bits ++ " bits") $
      check bits (vectorHeader ++ "function firstOrTrue (xs :: Vec n (bit :: Bool where bit)) -> (result :: Bool where result) is " ++
        "first matching case of xs: when VNil then true when VCons record{head = h} then h end case end function") `shouldSatisfy` isRight
    forM_
      [ "concatV t ys"
      , "VCons record{head = h, tail = ys}"
      , "VCons record{head = prelude.quot h 0, tail = concatV t ys}"
      , "concatV xs ys"
      ] $ \result -> it ("rejects an invalid indexed result or recursion at " ++ show bits ++ " bits: " ++ result) $
        case check bits (vectorSource result) of
          Left diagnostics -> map code diagnostics `shouldSatisfy` elem "total"
          Right _ -> expectationFailure "invalid indexed definition admitted"
    forM_ [("Int8",[0::Int,1]),("Nat",[1,2])] $ \(element,alphabet) ->
     it ("agrees with independent finite concatenation outcomes at " ++ show bits ++ " bits: " ++ element) $ do
      let inputs=concat [sequence (replicate size alphabet) | size<-[0..2]]
          vector []="VNil"
          vector (head:tail)="(VCons record{head = "++show head++", tail = "++vector tail++"})"
          laws=["law matrix"++show index++" is definition: concatV "++vector left++" "++vector right++
            " must be "++vector (left++right)++" end end" | (index,(left,right))<-zip [0::Int ..] [(l,r) | l<-inputs,r<-inputs]]
      program<-either (fail . show) pure (check bits (vectorSourceFor element "VCons record{head = h, tail = concatV t ys}"++unlines laws))
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

vectorHeader :: String
vectorHeader = unlines
  [ "unit predicateFacts"
  , "type Vec (n :: Whole) (a :: Type) is one of"
  , "  | VNil where n = 0"
  , "  | VCons of type record{head :: a tail :: Vec m a} where n = m + 1"
  , "end type"
  ]

vectorSource :: String -> String
vectorSource = vectorSourceFor "Int8"

vectorSourceFor :: String -> String -> String
vectorSourceFor element result = vectorHeader ++ unlines
  [ "function concatV (xs :: Vec n " ++ element ++ ") (ys :: Vec m " ++ element ++ ") -> Vec (n + m) " ++ element ++ " is"
  , "  first matching case of xs:"
  , "    when VNil then ys"
  , "    when VCons record{head = h, tail = t} then " ++ result
  , "  end case"
  , "end function"
  ]

headSource :: String -> String -> String
headSource element result = vectorHeader ++ "function firstOrOne (xs :: Vec n " ++ element ++ ") -> Nat is " ++
  "first matching case of xs: when VNil then 1 when VCons record{head = h} then " ++ result ++ " end case end function"

pairSource :: String -> String
pairSource selected = unlines
  [ "unit predicateFacts"
  , "type Packet (a :: Type) (b :: Type) is one of | Packed of type record{second :: b first :: a} end type"
  , "function selected (packet :: Packet Nat Whole) -> Nat is first matching case of packet:"
  , "when Packed record{" ++ selected ++ " = value} then value end case end function"
  ]

nestedSource :: String -> String
nestedSource element = unlines
  [ "unit predicateFacts"
  , "type Packet (a :: Type) is one of | Packed of type record{outer :: record{value :: a} flag :: Bool} end type"
  , "function selected (packet :: Packet " ++ element ++ ") -> Nat is first matching case of packet:"
  , "when Packed record{outer = record{value = value}} then value end case end function"
  ]

listSource :: String
listSource = listSourceFor "Nat"

listSourceFor :: String -> String
listSourceFor element = unlines
  [ "unit predicateFacts"
  , "type Packet (a :: Type) is one of | Packed of type record{items :: List a active :: Bool} end type"
  , "function selected (packet :: Packet " ++ element ++ ") -> List Nat is first matching case of packet:"
  , "when Packed record{items = values} then values end case end function"
  ]
