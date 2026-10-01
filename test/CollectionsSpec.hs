module CollectionsSpec (spec) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Core.Value (Value(..), compareValues, listValue)
import LawSpec.Collections (usedCollections)

import LawSpec.Frontend (compileCore)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Scalar (Scalar(..), textScalar)

source :: [String] -> Source
source = Source "collections.lawspec" . unlines . ("unit example.collections" :)

accepts :: [String] -> Expectation
accepts lines' = compileCore 64 defaultGeneration [source lines'] `shouldSatisfy` isRight

rejects :: String -> [String] -> Expectation
rejects fragment lines' = case compileCore 64 defaultGeneration [source lines'] of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

-- A law over checked definitions with a finite domain is evaluated by the
-- compiler when its evidence is discharged; a false one is refuted.
evaluated :: String -> String -> [String]
evaluated left right = ["law `l` is definition is `for all` (b :: Bool) . " ++ left ++ " = " ++ right ++ " end end"]

holds :: [String] -> Expectation
holds lines' = (compileCore 64 defaultGeneration [source lines'] >>= dischargeEvidence) `shouldSatisfy` isRight

refuted :: [String] -> Expectation
refuted lines' = case compileCore 64 defaultGeneration [source lines'] >>= dischargeEvidence of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "refuted"
  Right _ -> expectationFailure "expected the law to be refuted"

int :: Integer -> Value
int = ScalarValue . SInteger "Int32"

spec :: Spec
spec = describe "collections" $ do
  describe "the built-in unit" $ do
    it "is added only for the collections a source uses" $ do
      usedCollections [source ["f :: Int32 -> Set Int32"]] `shouldBe` ["Set", "Ordering"]
      usedCollections [source ["f :: Int32 -> Int32"]] `shouldBe` []
      usedCollections [source ["law `l` is definition is prelude.size (prelude.stackOf [1]) = 1 end end"]] `shouldBe` ["Stack"]
      usedCollections [source ["f :: Int32 -> KeyVal Text Int32"]] `shouldBe` ["KeyVal", "Entry", "Ordering"]
    it "is shadowed by a type the source declares" $ do
      usedCollections [source ["type Stack is Empty end", "f :: Stack -> Int32"]] `shouldBe` []
      accepts ["type Stack is | Empty | Push top :: Int8 end", "f :: Stack -> Int32", "g :: Int32 -> Set Int32"]
  describe "typing" $ do
    it "accepts operations over each collection" $
      accepts
        [ "f :: Set Int32 -> KeyVal Text Int32"
        , "law `l` is definition is `for all` (s :: Set Int32) (m :: KeyVal Text Int32) (q :: Queue Int8) ."
        , "  prelude.size (prelude.insert 1 s) >= prelude.size (prelude.keys m) - prelude.size q = true end end" ]
    it "requires a portable order of set elements and keys" $
      rejects "Keyed" ["law `l` is definition is `for all` (x :: Float64) . prelude.member x (prelude.setOf [x]) = true end end"]
    it "hides the containers' internal constructors" $
      rejects "SetItems" ["law `l` is definition is prelude.size (SetItems [1, 1]) = 2 end end"]
  describe "compile-time evaluation" $ do
    it "deduplicates and sorts a set" $ do
      holds (evaluated "prelude.toList (prelude.setOf [3, 1, 3, 2])" "[1, 2, 3]")
      refuted (evaluated "prelude.size (prelude.setOf [3, 1, 3])" "3")
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
