module ConditionalSpec (spec) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

compiles :: String -> Either String ()
compiles body = either (Left . concatMap show) (const (Right ())) $
  compileCore 64 defaultGeneration [Source "conditional.lawspec" ("unit example.conditional\n" ++ body)]

spec :: Spec
spec = describe "if then else" $ do
  it "proves a division safe in the branch its condition guards" $
    compiles (unlines
      [ "definition share (total :: Int32 where total >= 0 && total <= 1000) (n :: Int32 where n >= 0 && n <= 10) :: Int32 is"
      , "  if n > 0 then prelude.quot total n else 0"
      , "end" ]) `shouldBe` Right ()
  it "rejects a division its condition does not guard" $
    either (isInfixOf "nonzero denominator") (const False) (compiles (unlines
      [ "definition share (total :: Int32 where total >= 0 && total <= 1000) (n :: Int32 where n >= 0 && n <= 10) :: Int32 is"
      , "  if n >= 0 then prelude.quot total n else 0"
      , "end" ])) `shouldBe` True
  it "converts each branch to the expected type on its own" $
    compiles (unlines
      [ "definition withdraw (amount :: Int32 where amount >= 1 && amount <= 1000) (balance :: Int64 where balance >= 0 && balance <= 1000000) :: Pair Bool Int64 is"
      , "  if amount <= balance then Pair true (balance - amount) else Pair false balance"
      , "end" ]) `shouldBe` Right ()
  it "parses a conditional whose branches are a literal and a variable" $
    isRight (compiles (unlines
      [ "definition next (x :: Int32 where x >= 0 && x <= 10) :: Int32 is if x == 0 then 1 else x end" ])) `shouldBe` True
