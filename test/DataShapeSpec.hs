module DataShapeSpec (spec) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Common (Artifact(..))
import LawSpec.Compile
import LawSpec.Emit
import LawSpec.Model hiding (Expectation)

-- Products are named after their type and need no cast; sums are closed
-- families that native pattern matching checks for exhaustiveness.
shapes :: String -> String
shapes extra = unlines
  [ "unit example.shapes"
  , "type Size is | Small | Large extra :: Int32 end"
  , "type Drink is Drink size :: Size shots :: Int32 end"
  , "type Chain (a :: Type) is | Stop | More item :: a tail :: Chain a end"
  , "type Token is Token end"
  , "type Shape is | Shape | Other end"
  , extra
  , "f :: Drink -> Size -> Chain Int8 -> Token -> Shape -> Int32"
  ]

generated :: String -> String -> Either String String
generated target extra = case compile [Source "shapes.lawspec" (shapes extra)] of
  Left diagnostics -> Left (concatMap show diagnostics)
  Right (units, expanded) -> case emit target units expanded of
    Left diagnostics -> Left (concatMap show diagnostics)
    Right artifacts -> Right (concatMap artifactContent artifacts)

shows' :: String -> [String] -> Expectation
shows' target fragments = case generated target "" of
  Left failure -> expectationFailure failure
  Right source -> mapM_ (\fragment -> (fragment, fragment `isInfixOf` source) `shouldBe` (fragment, True)) fragments

lacks :: String -> [String] -> Expectation
lacks target fragments = case generated target "" of
  Left failure -> expectationFailure failure
  Right source -> mapM_ (\fragment -> (fragment, fragment `isInfixOf` source) `shouldBe` (fragment, False)) fragments

spec :: Spec
spec = describe "native data shapes" $ do
  it "Java: records for products, sealed interfaces of records for sums" $ do
    shows' "java"
      [ "public record Drink(lawspec.data.Size size, java.lang.Integer shots)"
      , "public sealed interface Size permits Size.Small, Size.Large"
      , "record Small() implements Size"
      , "record More<T0>(T0 item, lawspec.data.Chain<T0> tail) implements Chain<T0>"
      , "public record Token()"
      , "record ShapeCase() implements Shape"
      , "record Other() implements Shape" ]
    lacks "java" ["DrinkCase", "SmallCase", "OtherCase"]
  it "Java: rejects a record component that overrides an Object method" $
    generated "java" "type Bad is Bad hashCode :: Int32 end\ng :: Bad -> Int32"
      `shouldSatisfy` either (isInfixOf "java.lang.Object.hashCode()") (const False)
  it "Kotlin: data classes and objects" $ do
    shows' "kotlin"
      [ "data class Drink(", "val shots: kotlin.Int"
      , "sealed interface Size", "data object Small : lawspec.data.Size"
      , "data class Large(", "class Stop<T0> : lawspec.data.Chain<T0>"
      , "data object Token", "data object ShapeCase : lawspec.data.Shape" ]
    lacks "kotlin" ["DrinkCase", "SmallCase"]
  it "Go: a product is a plain struct" $ do
    shows' "go" ["type Drink struct", "type SizeSmall struct", "type Size interface"]
    lacks "go" ["DrinkDrink", "type Drink interface"]
  it "Rust: a product is a struct and a sum an enum" $ do
    shows' "rust" ["pub struct Drink {", "pub size: Size,", "pub struct Token;", "pub enum Size {"]
    lacks "rust" ["Self::Drink", "pub enum Drink"]
  it "Python, JavaScript, TypeScript and Haskell name a product after its type" $ do
    shows' "python" ["class Drink:", "class SizeSmall(Size):"]
    lacks "python" ["DrinkDrink"]
    shows' "typescript" ["export class Drink ", "export type Size = SizeSmall | SizeLarge;"]
    lacks "typescript" ["DrinkDrink", "export type Drink "]
    shows' "javascript" ["export class Drink "]
    lacks "javascript" ["DrinkDrink"]
    shows' "haskell" ["Drink"]
    lacks "haskell" ["DrinkDrink"]
