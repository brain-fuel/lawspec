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
      compile [Source "capture.lawspec" "unit capture\nx :: Int32 -> Text\ng :: Int32 -> Text\nlaw `ok` is definition is `equivalent` x g end example `zero` is x = 0 expect g x = \"0\" end end"] `shouldSatisfy` isRight
    it "accepts the reverse round trip with quantified Text" $
      compile [source (concrete "`left inverse` f g")] `shouldSatisfy` isRight
    it "rejects recursive expansion" $
      compile [source (concrete "`codec`")] `shouldSatisfy` isLeft
    it "rejects unknown functions" $
      compile [source (concrete "`left inverse` missing f")] `shouldSatisfy` isLeft
    it "rejects missing Eq constraints on generic laws" $
      compile [Source "generic.lawspec" "unit generic\nlaw `id` (f :: a -> a) is definition is `for all` (x :: a) . f x = x end end"] `shouldSatisfy` isLeft
    it "does not specialize rigid generic parameters to hide a mismatch" $
      compile [Source "generic.lawspec" "unit generic\nlaw `bad` (f :: a -> b) requires Eq a is definition is `for all` (x :: a) . f x = x end end"] `shouldSatisfy` isLeft
    it "rejects an incorrect inherited example input" $
      compile [source "law `codec` is definition is `left inverse` g f end example `bad` is y = 1 expect g (f x) = 1 end end"] `shouldSatisfy` isLeft
    it "rejects out-of-range examples" $
      compile [source "law `codec` is definition is `left inverse` g f end example `bad` is x = 2147483648 expect g (f x) = 0 end end"] `shouldSatisfy` isLeft
    it "accepts multiple independent quantified inputs" $
      compile [source (concrete "`for all` (x :: Int32) (y :: Int32) . g (f x) = y")] `shouldSatisfy` isRight
    it "does not capture an argument named like an inherited input" $
      compile [Source "capture.lawspec" "unit capture\nx :: Int32 -> Text\ng :: Text -> Int32\nlaw `ok` is definition is `left inverse` g x end end"] `shouldSatisfy` isRight
    it "checks Text and mixed example fixtures" $ do
      mapM_ (\name -> do
        text <- readFile ("examples/specs/" ++ name ++ ".lawspec")
        compile [Source (name ++ ".lawspec") text] `shouldSatisfy` isRight) ["slug", "canonical_url", "mixed_inputs"]
    it "rejects example values that do not match input types" $ do
      compile [Source "bad.lawspec" "unit bad\nf :: Text -> Text\nlaw `bad` is definition is `idempotent` f end example `bad` is x = 42 expect f x = 42 end end"] `shouldSatisfy` isLeft
      compile [Source "bad.lawspec" "unit bad\nf :: Int32 -> Int32\nlaw `bad` is definition is `idempotent` f end example `bad` is x = \"42\" expect f x = 42 end end"] `shouldSatisfy` isLeft
    it "rejects non-scalar Text values" $
      compile [Source "bad.lawspec" ("unit bad\nf :: Text -> Text\nlaw `bad` is definition is `idempotent` f end example `bad` is x = \"" ++ ['\xD800'] ++ "\" expect f x = \"\" end end")] `shouldSatisfy` isLeft
    it "requires the same input and output types for idempotence" $
      compile [Source "bad.lawspec" "unit bad\nf :: Text -> Int32\nlaw `bad` is definition is `idempotent` f end end"] `shouldSatisfy` isLeft
    it "requires an expected result in every example" $
      compile [Source "missing.lawspec" "unit missing\nf :: Int32 -> Int32\nlaw `identity` is definition is `idempotent` f end example `zero` is x = 0 end end"] `shouldSatisfy` (\r -> case r of Left ds -> any (isInfixOf "requires at least one expect" . message) ds; _ -> False)
    it "type-checks expectation results" $
      compile [Source "wrong.lawspec" "unit wrong\nf :: Int32 -> Text\nlaw `same` is definition is `equivalent` f f end example `zero` is x = 0 expect f x = 0 end end"] `shouldSatisfy` isLeft
    it "supports composed expectation expressions" $
      compile [source "law `codec` is definition is `left inverse` g f end example `negative` is x = -42 expect (g . f) x = -42 end end"] `shouldSatisfy` isRight
  describe "predicates" $ do
    it "compiles the port and Boolean examples" $ do
      mapM_ (\name -> do
        text <- readFile ("examples/specs/" ++ name ++ ".lawspec")
        compile [Source (name ++ ".lawspec") text] `shouldSatisfy` isRight) ["parse_port", "boolean_flags"]
    it "rejects ambiguous inputs introduced by a guarded nested law call" $
      compile [Source "guards.lawspec" "unit guards\np :: Int32 -> Bool\nf :: Int32 -> Int32\nlaw `check` is definition is `for all` (x :: Int32) . p x implies `idempotent` f end end"] `shouldSatisfy` isLeft
    it "preserves caller predicate arguments named like inherited inputs" $ do
      let text = "unit guards\nx :: Int32 -> Bool\nf :: Int32 -> Text\ng :: Text -> Int32\nlaw `check` is definition is `left inverse when` x g f end end"
      case compile [Source "guards.lawspec" text] of
        Right (_, [e]) -> do
          prettyExpanded e `shouldBe` "for all (x :: Int32) . x (x) implies g (f (x)) = x"
          guards e `shouldBe` [Apply (Var "x") (Var (inputId (head (inputs e))))]
        other -> expectationFailure (show other)
    it "accepts nested implications and Boolean predicate conclusions" $
      compile [Source "bool.lawspec" "unit bools\nf :: Bool -> Bool\nlaw `nested` is definition is `for all` (x :: Bool) . x implies f x implies true end example `enabled` is x = true expect f x = true end end"] `shouldSatisfy` isRight
    it "requires Boolean conditions and predicate conclusions" $ do
      mapM_ (\d -> compile [source (concrete ("`for all` (x :: Int32) . " ++ d))] `shouldSatisfy` isLeft)
        ["x implies x = x", "f x implies x = x", "x", "f x"]
    it "rejects unknown guard values and Boolean/int expectation mismatches" $ do
      compile [source (concrete "`for all` (x :: Int32) . missing x implies x = x")] `shouldSatisfy` isLeft
      compile [Source "bad.lawspec" "unit bad\nf :: Int32 -> Bool\nlaw `check` is definition is `satisfies` f end example `zero` is x = 0 expect f x = 1 end end"] `shouldSatisfy` isLeft
    it "checks generic predicate constraints without requiring Eq of the input" $
      compile [Source "generic.lawspec" "unit generic\nlaw `predicate` (p :: a -> Bool) is definition is `satisfies` p end end"] `shouldSatisfy` isRight
  describe "algebra and currying" $ do
    it "compiles every algebra and partial-application example" $ do
      mapM_ (\n -> do
        text <- readFile ("examples/specs/" ++ n ++ ".lawspec")
        compile [Source (n ++ ".lawspec") text] `shouldSatisfy` isRight) ["algebra", "currying"]
    it "accepts exactly the generic commutative and associative signatures" $ do
      let generic name body = Source "generic.lawspec" ("unit generic\nlaw `" ++ name ++ "` (f :: a -> a -> a) requires Eq a is definition is " ++ body ++ " end end")
      compile [generic "commutes" "`for all` (x :: a) (y :: a) . f x y = f y x"] `shouldSatisfy` isRight
      compile [generic "associates" "`for all` (x :: a) (y :: a) (z :: a) . f (f x y) z = f x (f y z)"] `shouldSatisfy` isRight
    it "checks scalar identity parameters and rejects wrong types or arities" $ do
      let spec d = Source "arity.lawspec" ("unit arity\nf :: Int32 -> Int32 -> Int32\nlaw `check` is definition is " ++ d ++ " end end")
      compile [spec "`left identity` f 0"] `shouldSatisfy` isRight
      mapM_ (\d -> compile [spec d] `shouldSatisfy` isLeft)
        ["`left identity` f true", "`commutative` (f 1)", "`for all` (x :: Int32) . f x = x", "`for all` (x :: Int32) . f x x x = x"]
    it "retains every conjunct and shared conditional scope" $ do
      let spec = Source "both.lawspec" "unit both\nlaw `check` is definition is `for all` (x :: Bool) . x implies (x = true and true = x) end end"
      case compile [spec] of
        Right (_, [e]) -> case assertion e of
          AssertImplies _ (AssertAll [AssertEqual _ _, AssertEqual _ _]) -> pure ()
          other -> expectationFailure (show other)
        other -> expectationFailure (show other)
    it "requires Eq constraints for all generic equality conclusions" $
      compile [Source "bad.lawspec" "unit bad\nlaw `check` (f :: a -> a -> a) is definition is `commutative` f end end"] `shouldSatisfy` isLeft
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
