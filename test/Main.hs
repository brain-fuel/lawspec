module Main where
import Test.Hspec
import LawSpec.Compile
import LawSpec.Model
import LawSpec.Emit
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)

source :: String -> Source
source body = Source "test.lawspec" ("unit test.codec\nf :: Int32 -> Text\ng :: Text -> Int32\n" ++ body)
concrete :: String -> String
concrete d = "law `codec` is definition is " ++ d ++ " end end\n"
main :: IO ()
main = hspec $ do
  describe "compiler" $ do
    it "checks the bundled prelude" $ compile [] `shouldBe` Right ([],[])
    it "expands the exact scratch example" $ do
      s <- readFile "examples/specs/atoi_codec.lawspec"
      case compile [Source "codec.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (_, [e]) -> do
          map inputName (inputs e) `shouldBe` ["x"]
          prettyExpanded e `shouldBe` "for all (x :: Int32) . atoi (itoa (x)) = x"
          length (trace e) `shouldBe` 3
        Right other -> expectationFailure (show other)
    it "expands equivalent with Text and Int32 results and inherited examples" $ do
      s <- readFile "examples/specs/equivalent.lawspec"
      case compile [Source "equivalent.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (_, es) -> do
          map prettyExpanded es `shouldBe`
            ["for all (x :: Int32) . render (x) = referenceRender (x)",
             "for all (x :: Int32) . clamp (x) = referenceClamp (x)"]
          map (map inputName . inputs) es `shouldBe` [["x"], ["x"]]
          map (length . examples . original) es `shouldBe` [2, 2]
    it "requires equality of the output type when wrapping equivalent" $ do
      let wrapper eq = Source "generic.lawspec" ("unit generic\nlaw `alternatives` (f :: a -> b) (g :: a -> b) requires Eq " ++ eq ++ " is definition is `equivalent` f g end end")
      compile [wrapper "b"] `shouldSatisfy` isRight
      compile [wrapper "a"] `shouldSatisfy` isLeft
    it "rejects equivalent functions with different result types" $
      compile [Source "bad.lawspec" "unit bad\nf :: Int32 -> Text\ng :: Int32 -> Int32\nlaw `bad` is definition is `equivalent` f g end end"] `shouldSatisfy` isLeft
    it "rejects equivalent functions with different input types" $
      compile [Source "bad.lawspec" "unit bad\nf :: Int32 -> Int32\ng :: Text -> Int32\nlaw `bad` is definition is `equivalent` f g end end"] `shouldSatisfy` isLeft
    it "expands equivalent without capturing an implementation named x" $
      compile [Source "capture.lawspec" "unit capture\nx :: Int32 -> Text\ng :: Int32 -> Text\nlaw `ok` is definition is `equivalent` x g end example `zero` is x = 0 end end"] `shouldSatisfy` isRight
    it "rejects mismatched function directions" $
      compile [source (concrete "`left inverse` f g")] `shouldSatisfy` isLeft
    it "rejects recursive expansion" $
      compile [source (concrete "`codec`")] `shouldSatisfy` isLeft
    it "rejects unknown functions" $
      compile [source (concrete "`left inverse` missing f")] `shouldSatisfy` isLeft
    it "rejects missing Eq constraints on generic laws" $
      compile [Source "generic.lawspec" "unit generic\nlaw `id` (f :: a -> a) is definition is `for all` (x :: a) . f x = x end end"] `shouldSatisfy` isLeft
    it "does not specialize rigid generic parameters to hide a mismatch" $
      compile [Source "generic.lawspec" "unit generic\nlaw `bad` (f :: a -> b) requires Eq a is definition is `for all` (x :: a) . f x = x end end"] `shouldSatisfy` isLeft
    it "rejects an incorrect inherited example input" $
      compile [source "law `codec` is definition is `left inverse` g f end example `bad` is y = 1 end end"] `shouldSatisfy` isLeft
    it "rejects out-of-range examples" $
      compile [source "law `codec` is definition is `left inverse` g f end example `bad` is x = 2147483648 end end"] `shouldSatisfy` isLeft
    it "accepts multiple independent quantified inputs" $
      compile [source (concrete "`for all` (x :: Int32) (y :: Int32) . g (f x) = y")] `shouldSatisfy` isRight
    it "does not capture an argument named like an inherited input" $
      compile [Source "capture.lawspec" "unit capture\nx :: Int32 -> Text\ng :: Text -> Int32\nlaw `ok` is definition is `left inverse` g x end end"] `shouldSatisfy` isRight
  describe "emission" $ do
    it "emits tests and user-owned adapters for all seven targets" $ do
      s <- readFile "examples/specs/atoi_codec.lawspec"
      case compile [Source "codec.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> mapM_ (\t -> case emit t us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            map ownership fs `shouldBe` ["user","generated"]
            artifactContent (last fs) `shouldSatisfy` isInfixOf "2147483647") targets

    it "retains executable laws even without implementation functions" $ do
      let input = Source "pure.lawspec" "unit purelaw\nlaw `reflexive` is definition is `for all` (x :: Int32) . x = x end end"
      case compile [input] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> case emit "python" us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            length fs `shouldBe` 2
            artifactContent (last fs) `shouldSatisfy` (not . isInfixOf "from purelaw import")
    it "moves generated imports with a custom layout" $ do
      s <- readFile "examples/specs/atoi_codec.lawspec"
      case compile [Source "codec.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> case emitWithLayout "javascript" (Just "lib") (Just "checks/unit") us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            artifactPath (head fs) `shouldBe` "lib/example/atoi_codec.mjs"
            artifactContent (last fs) `shouldSatisfy` isInfixOf "../../lib/example/atoi_codec.mjs"
