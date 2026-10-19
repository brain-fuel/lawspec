-- | The built-in collections unit: typing, compile-time evaluation and the portable order.
module CollectionsSpec (test_collectionsAreTypedEvaluatedAndOrderedPortably) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Core.Value (Value(..), compareValues, listValue)
import LawSpec.Collections (usedCollectionsCanonical)

import LawSpec.Frontend (compileCore)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Scalar (Scalar(..), textScalar)
import LawSpec.Testing (planTesting, plannedUnits, plannedProperties, plannedProperty, generatorRequirements, generatorIndex, generatorPredicates)

usedCollections :: [String] -> [String]
usedCollections sources = usedCollectionsCanonical sources []

source :: [String] -> Source
source body = Source "collections.lawspec" (unlines (["unit example.collections"] ++ body ++ ["end unit"]))

sourceText :: [String] -> String
sourceText lines' = let Source _ text = source lines' in text

accepts :: [String] -> Expectation
accepts lines' = compileCore 64 defaultGeneration [source lines'] `shouldSatisfy` isRight

rejects :: String -> [String] -> Expectation
rejects fragment lines' = case compileCore 64 defaultGeneration [source lines'] of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

-- | A law over checked definitions with a finite domain is evaluated by the
-- compiler when its evidence is discharged; a false one is refuted.
evaluated :: String -> String -> [String]
evaluated left right = ["law \"|l| is definition: for all (b :: Bool) => " ++ left ++ " = " ++ right ++ " end for all end definition end law"]

holds :: [String] -> Expectation
holds lines' = (compileCore 64 defaultGeneration [source lines'] >>= dischargeEvidence) `shouldSatisfy` isRight

refuted :: [String] -> Expectation
refuted lines' = case compileCore 64 defaultGeneration [source lines'] >>= dischargeEvidence of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "refuted"
  Right _ -> expectationFailure "expected the law to be refuted"

int :: Integer -> Value
int = ScalarValue . SInteger "Int32"

-- | A law over a set or a map must give the same answer on every target, which
-- needs one order and one evaluation independent of each language's hashing.
-- ref:DEC-portable-total-order-collections ref:REQ-portable-collections
test_collectionsAreTypedEvaluatedAndOrderedPortably :: Spec
test_collectionsAreTypedEvaluatedAndOrderedPortably = describe "collections" $ do
  describe "generation" $
    it "retains the size predicate when an explicit record payload needs checked generation" $
      case compileCore 64 defaultGeneration [source [ "law sized is definition: for all (s :: SizedStack 3 Int8) => prelude.sizedStackItems s = prelude.sizedStackItems s end for all end definition end law" ]] >>= planTesting of
        Left ds -> expectationFailure (show ds)
        Right plan -> [(generatorIndex r, null (generatorPredicates r)) | u <- plannedUnits plan, pp <- plannedProperties u,
                      C.propertyName (plannedProperty pp) == "sized", r <- generatorRequirements pp]
          `shouldBe` [(Nothing, False)]
  describe "the built-in unit" $ do
    it "is added only for the collections a source uses" $ do
      usedCollections [sourceText ["f :: Int32 -> SortedSet Int32"]] `shouldBe` ["Set", "Ordering"]
      usedCollections [sourceText ["f :: Int32 -> Int32"]] `shouldBe` []
      usedCollections [sourceText [ "law \"|l| is definition : prelude.size (prelude.stackOf [1]) = 1 end definition end law" ]] `shouldBe` ["Stack"]
      usedCollections [sourceText ["f :: Int32 -> KeyVal Text Int32"]] `shouldBe` ["KeyVal", "Entry", "Ordering"]
    it "is shadowed by a type the source declares" $ do
      usedCollections [sourceText [ "type Stack is one of Empty end type\n"
                                  , "f :: Stack -> Int32" ]] `shouldBe` []
      accepts [ "type Stack is one of | Empty | Push  of type Int8 end type\n"
              , "f :: Stack -> Int32"
              , "g :: Int32 -> SortedSet Int32" ]
    it "is shadowed only in the source that declares the type" $ do
      let own = Source "own.lawspec" (unlines [ "unit example.own"
                                               ++ "\n", ""
                                              , "type Stack is one of | Empty | Push  of type Int8 end type\n"
                                              , "f :: Stack -> Int32"
                                              , "\nend unit" ])
          builtin = Source "builtin.lawspec" (unlines [ "unit example.builtin"
                                                       ++ "\n", ""
                                                      , "g :: List Int8 -> Stack Int8"
                                                      , "\nend unit" ])
      usedCollections [text | Source _ text <- [own, builtin]] `shouldBe` ["Stack"]
      compileCore 64 defaultGeneration [own, builtin] `shouldSatisfy` isRight
  describe "typing" $ do
    it "accepts operations over each collection" $
      accepts
        [ "f :: SortedSet Int32 -> KeyVal Text Int32"
        , "law \"|l| is definition : for all (s :: SortedSet Int32) (m :: KeyVal Text Int32) (q :: Queue Int8) =>"
        , "  prelude.size (prelude.sortedSetInsert 1 s) >= prelude.size (prelude.keys m) - prelude.size q = true end for all end definition end law" ]
    it "requires a portable order of set elements and keys" $
      rejects "Keyed" [ "law \"|l| is definition : for all (x :: Float64) => prelude.member x (prelude.sortedSetOf [x]) = true end for all end definition end law" ]
    it "hides the containers' internal constructors" $
      rejects "SetItems" [ "law \"|l| is definition : prelude.size (SetItems [1, 1]) = 2 end definition end law" ]
  describe "compile-time evaluation" $ do
    it "deduplicates and sorts a set" $ do
      holds (evaluated "prelude.toList (prelude.sortedSetOf [3, 1, 3, 2])" "[1, 2, 3]")
      refuted (evaluated "prelude.size (prelude.sortedSetOf [3, 1, 3])" "3")
    it "keeps the latest value for a key" $
      holds (evaluated "prelude.lookup \"a\" (prelude.keyValOf [Entry \"a\" 1, Entry \"a\" 2])" "Just 2")
    it "keeps queues first in, first out and stacks last in, first out" $ do
      holds (evaluated "prelude.front (prelude.enqueue 2 (prelude.queueOf [1]))" "Just 1")
      holds (evaluated "prelude.peek (prelude.push 2 (prelude.stackOf [1]))" "Just 2")
      holds (evaluated "prelude.peekBack (prelude.popBack (prelude.dequeOf [1, 2, 3]))" "Just 2")
    it "orders with prelude.compare" $
      holds (evaluated "prelude.compare \"b\" \"a\"" "Greater")
  describe "the portable order" $ do
    let compareOf a b = compareValues a b
    it "orders exact numbers by value and text by code point" $ do
      compareOf (int 2) (int 10) `shouldBe` Right LT
      compareOf (ScalarValue (textScalar "b")) (ScalarValue (textScalar "ab")) `shouldBe` Right GT
    it "orders lists element by element, a prefix first" $ do
      let list = listValue (C.Constructor "Int32" []) . map int
      compareOf (list [1, 2]) (list [1, 2, 0]) `shouldBe` Right LT
      compareOf (list [2]) (list [1, 9]) `shouldBe` Right GT
    it "puts Nothing before Just" $ do
      let maybeType = C.Constructor "Maybe" [C.TypeArgument (C.Constructor "Int32" [])]
      compareOf (DataValue maybeType (C.Id "Maybe::Nothing") []) (DataValue maybeType (C.Id "Maybe::Just") [int 0])
        `shouldBe` Right LT
    it "has no order for floats" $
      compareOf (ScalarValue (SFloat "Float64" "0")) (ScalarValue (SFloat "Float64" "0")) `shouldSatisfy` either (const True) (const False)
