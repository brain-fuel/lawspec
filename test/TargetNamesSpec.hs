-- | Names of definitions and adapters in target code.
module TargetNamesSpec (test_targetNamesNeverCollideWithKeywords) where

import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.TargetNames (nativeName)
import LawSpec.Testing (planTesting)

keywords :: String
keywords = unlines
  [ "unit example.keywords"
  , "definition short (x :: BigInt) :: Bool is x < 10 end"
  , "class :: BigInt -> BigInt"
  , "law `class is short` is definition is `for all` (x :: BigInt) . short (class x) = short x end end" ]

emitted :: String -> String -> Either [Diagnostic] [(String, String)]
emitted target ownership' = do
  program <- compileCore 64 defaultGeneration [Source "keywords.lawspec" keywords]
  files <- planTesting program >>= emitPlan target
  pure [(artifactPath f, artifactContent f) | f <- files, ownership f == ownership' || ownership' == "any"]

contents :: String -> String -> String
contents target ownership' = either (error . show) (concatMap snd) (emitted target ownership')

-- | A LawSpec name may be a keyword in some target language, so it must be
-- escaped consistently there while Core keeps the declared name.
-- ref:DEC-readable-notation ref:REQ-target-name-escaping
test_targetNamesNeverCollideWithKeywords :: Spec
test_targetNamesNeverCollideWithKeywords = describe "target names" $ do
  it "escape a keyword of the target with a leading underscore" $ do
    nativeName "java" "short" `shouldBe` "_short"
    nativeName "python" "short" `shouldBe` "short"
    nativeName "python" "lambda" `shouldBe` "_lambda"
    nativeName "rust" "class" `shouldBe` "class"
    nativeName "haskell" "class" `shouldBe` "_class"
  it "never escape a Go name, which is exported capitalized" $
    nativeName "go" "func" `shouldBe` "func"
  it "are idempotent" $
    nativeName "java" (nativeName "java" "short") `shouldBe` "_short"
  it "escape definitions and adapters in emitted code and stubs" $ do
    contents "java" "any" `shouldSatisfy` isInfixOf " _short("
    contents "java" "user" `shouldSatisfy` isInfixOf " _class("
    contents "python" "user" `shouldSatisfy` isInfixOf "def _class("
    contents "python" "user" `shouldNotSatisfy` isInfixOf "short"
    contents "rust" "user" `shouldSatisfy` isInfixOf "pub fn class("
  it "keep the declared name in Core" $
    case compileCore 64 defaultGeneration [Source "keywords.lawspec" keywords] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> [C.declarationName d | u <- C.programUnits program, d <- C.unitDeclarations u]
        `shouldSatisfy` (\names -> "short" `elem` names && "class" `elem` names)
