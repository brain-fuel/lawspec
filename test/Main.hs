module Main where
import Test.Hspec
import LawSpec.Compile
import LawSpec.Model
import qualified LawSpec.Domain as D
import LawSpec.Eval
import LawSpec.Emit
import LawSpec.Scalar
import LawSpec.Parser (parseSource)
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

  describe "portable scalars" $ do
    it "recognizes every scalar domain and both presence constructors" $ do
      let types = map primitiveName primitives ++ ["Optional (Nullable Int8)","Nullable (Optional Bool)"]
      mapM_ (\t -> compile [Source "all" ("unit domain\nf :: " ++ t ++ " -> " ++ t ++ "\nlaw `identity` is definition is `equivalent` f f end end")] `shouldSatisfy` isRight) types
    it "compiles the executable scalar and adapter examples" $ do
      mapM_ (\n -> readFile ("examples/specs/" ++ n ++ ".lawspec") >>= \s -> compile [Source n s] `shouldSatisfy` isRight) ["scalars","scalar_adapters"]
    it "promotes primitive integer arithmetic to Integer and division to Rational" $ do
      let env = [("x",Named "Int8")]
      fmap expressionType (typedExpression 64 env (Binary "+" (Var "x") (Number 1))) `shouldBe` Right (Named "Integer")
      fmap expressionType (typedExpression 64 env (Binary "/" (Var "x") (Number 2))) `shouldBe` Right (Named "Rational")
    it "checks contextual literals at both machine widths" $ do
      let s = Source "width" "unit width\nf :: IntSize -> IntSize\nlaw `id` is definition is `equivalent` f f end example `large` is x = 2147483648 expect f x = 2147483648 end end"
      compileWithProfile 32 [s] `shouldSatisfy` isLeft
      compileWithProfile 64 [s] `shouldSatisfy` isRight
      compileWithProfile 16 [] `shouldSatisfy` isLeft
    it "rejects implicit exact/inexact mixing and Bool arithmetic" $ do
      let env = [("x",Named "Float32"),("y",Named "Int8"),("b",Named "Bool")]
      typedExpression 64 env (Binary "+" (Var "x") (Var "y")) `shouldSatisfy` isLeft
      typedExpression 64 env (Binary "+" (Var "b") (Number 1)) `shouldSatisfy` isLeft
      typedExpression 64 env (Binary "+" (Var "x") (Apply (Var "prelude.Float32") (Var "y"))) `shouldSatisfy` isRight
    it "checks operator precedence while preserving signed application" $ do
      let spec text = parseSource (Source "precedence" ("unit p\nlaw `p` is definition is `for all` (x :: Int8) . " ++ text ++ " = x end end"))
      case spec "x + 2 * 3" of
        Right u -> definition (head (laws u)) `shouldBe` Forall [("x",Named "Int8")] (Equal (Binary "+" (Var "x") (Binary "*" (Number 2) (Number 3))) (Var "x"))
        Left ds -> expectationFailure (show ds)
      case spec "f -42" of
        Right u -> definition (head (laws u)) `shouldBe` Forall [("x",Named "Int8")] (Equal (Apply (Var "f") (Number (-42))) (Var "x"))
        Left ds -> expectationFailure (show ds)
    it "validates raw domains without surrogate replacement" $ do
      validateScalar 64 (SSequence "Text" [55296]) `shouldSatisfy` isLeft
      validateScalar 64 (SSequence "CodePointText" [55296]) `shouldSatisfy` isRight
      validateScalar 64 (SSequence "Utf16Text" [55296,65535]) `shouldSatisfy` isRight
      validateScalar 64 (SSequence "Bytes" [256]) `shouldSatisfy` isLeft
      validateScalar 64 (SCharacter "Char" 128512) `shouldSatisfy` isRight
      validateScalar 64 (SCharacter "CodeUnit16" 128512) `shouldSatisfy` isLeft
    it "checks exact conversion and rational canonicalization" $ do
      convertScalar 64 "Int8" (SRational 1 2) `shouldSatisfy` isLeft
      convertScalar 64 "Int8" (SInteger "BigInt" 128) `shouldSatisfy` isLeft
      convertScalar 64 "Decimal" (SRational 1 3) `shouldSatisfy` isLeft
      validateScalar 64 (SRational 4 (-6)) `shouldBe` Right (SRational (-2) 3)
      validateScalar 64 (SRational 1 0) `shouldSatisfy` isLeft
    it "places generated runtimes in source directories with custom layouts" $ do
      s <- readFile "examples/specs/scalars.lawspec"
      case compile [Source "scalars" s] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> case emitWithLayout "javascript" (Just "lib") (Just "checks/unit") us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            [artifactPath a | a <- fs, artifactPlacement a == "source", ownership a == "generated"] `shouldBe` ["lib/lawspec_runtime.mjs"]
            artifactContent (fs !! 1) `shouldSatisfy` isInfixOf "../../lib/lawspec_runtime.mjs"

    it "infers tagged presence literals in law assertions" $ do
      compile [Source "absence" "unit absence\nlaw `missing` is definition is `for all` (x :: Optional Int8) . x = undefined end end"] `shouldSatisfy` isRight
      compile [Source "presence" "unit presence\nlaw `present` is definition is `for all` (x :: Optional Int8) . x = optional(7) end end"] `shouldSatisfy` isRight
    it "keeps explicit Decimal constructors distinct from contextual decimal tokens" $ do
      let env = [("x",Named "Float32")]
      typedExpression 64 env (Binary "+" (Var "x") (DecimalNumber 1 (-1))) `shouldSatisfy` isRight
      typedExpression 64 env (Binary "+" (Var "x") (ScalarLit (SDecimal 1 (-1)))) `shouldSatisfy` isLeft
    it "retains promoted operation types and checked bridge targets in the IR" $ do
      let env = [("f",Arrow (Named "Int8") (Named "Int8")),("x",Named "Int8")]
      case typedExpression 64 env (Apply (Var "f") (Binary "+" (Var "x") (Number 0))) of
        Right ir -> do
          expressionType (operands ir !! 1) `shouldBe` Named "Integer"
          requiredConversion (operands ir !! 1) `shouldBe` Just (Named "Int8")
        Left e -> expectationFailure e

    it "specializes generic laws over nested presence types" $ do
      let s = Source "generic-presence" "unit generic_presence\nf :: Optional (Nullable Int8) -> Optional (Nullable Int8)\nlaw `identity` (g :: Optional a -> Optional a) requires Eq (Optional a) is definition is `for all` (x :: Optional a) . g x = x end end\nlaw `concrete` is definition is `identity` f end end"
      compile [s] `shouldSatisfy` isRight


  describe "dependent refinements" $ do
    let spec body = Source "refinement.lawspec" ("unit refinement\n" ++ body)
        law qs body = "law `check` is definition is `for all` " ++ qs ++ " . " ++ body ++ " end end"
    it "compiles parameterized refinements and independently executable contracts" $ do
      text <- readFile "examples/specs/refinements.lawspec"
      case compile [Source "refinements" text] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> do
          length (contracts (head us)) `shouldBe` 6
          length (filter ((== "contract") . propertyKind) es) `shouldBe` 6
          length (refinements (head us)) `shouldBe` 3
    it "finds exactly the mathematical Int8 overflow pairs" $ do
      let s = spec (law "(x :: Int8) (y :: Int8 where y > Int8.max - x)" "x + y > Int8.max")
      case compile [s] of
        Left ds -> expectationFailure (show ds)
        Right (_, [e]) -> do
          let expected = [[SInteger "Int8" x,SInteger "Int8" y] | x <- [-128..127], y <- [-128..127], x+y>127]
          D.finiteTuples 64 defaultGeneration{exhaustiveLimit=65536} (inputs e) `shouldBe` Right (Just expected)
          length expected `shouldBe` 8128
          all (\xs -> case xs of [SInteger _ x,SInteger _ y] -> x>0 && x+y>=128 && x+y<=254; _ -> False) expected `shouldBe` True
    it "rejects examples outside the dependent domain" $
      compile [spec ("law `bad` is definition is `for all` (x :: Int8) (y :: Int8 where y > Int8.max - x) . x + y > Int8.max end example `invalid` is x = 0 y = 127 expect x + y = 127 end end")] `shouldSatisfy` isLeft
    it "rejects empty finite domains and non-Boolean refinements" $ do
      compile [spec (law "(x :: Bool where false)" "x = x")] `shouldSatisfy` isLeft
      compile [spec (law "(x :: Int8 where x)" "x = x")] `shouldSatisfy` isLeft
    it "permits a prefix with no continuation without treating the whole domain as empty" $
      compile [spec (law "(x :: Int8) (y :: Int8 where y > Int8.max - x)" "x + y > Int8.max")] `shouldSatisfy` isRight
    it "rejects adapter calls in predicates" $
      compile [spec ("valid :: Int8 -> Bool\n" ++ law "(x :: Int8 where valid x)" "x = x")] `shouldSatisfy` isLeft
    it "rejects forward value references and recursive aliases" $ do
      compile [spec (law "(x :: Int8 where x > y) (y :: Int8)" "x = x")] `shouldSatisfy` isLeft
      compile [spec "refinement Loop is (x :: Loop where true) end"] `shouldSatisfy` isLeft
    it "resolves forward refinement declarations and zero-parameter aliases" $
      compile [spec ("identity :: Positive -> Positive\nrefinement Positive is (x :: Int8 where x > 0) end")] `shouldSatisfy` isRight
    it "checks capabilities on unused generic refinements" $ do
      compile [spec "refinement Positive (T :: Type) is (x :: T where x > 0) end"] `shouldSatisfy` isLeft
      compile [spec "refinement Positive (T :: Type) requires Ordered T is (x :: T where x > 0) end"] `shouldSatisfy` isRight
    it "rejects invalid scalar specializations" $ do
      compile [spec ("refinement Positive (T :: Type) requires Integer T is (x :: T where x > 0) end\n" ++ law "(x :: Positive Float64)" "x = x")] `shouldSatisfy` isLeft
      compile [spec (law "(x :: Integer)" "x < Integer.max")] `shouldSatisfy` isLeft
    it "supports abstract results and integer-constrained reusable laws" $
      compile [spec ("f :: Int8 -> Integer\nlaw `successor` (g :: a -> b) requires Integer a Integer b is definition is `for all` (x :: a) . g x = x + 1 end end\nlaw `instance` is definition is `successor` f end end")] `shouldSatisfy` isRight
    it "checks dependent postcondition scope" $ do
      compile [spec "f :: (x :: Int8) -> (r :: Integer where r == x + 1)"] `shouldSatisfy` isRight
      compile [spec "f :: (x :: Int8) -> (r :: Integer where r == missing)"] `shouldSatisfy` isLeft
    it "composes nested presence refinements" $
      compile [spec ("refinement Positive is (x :: Int8 where x > 0) end\n" ++ law "(x :: Optional (Nullable Positive))" "x = x")] `shouldSatisfy` isRight
    it "preserves short circuiting in pure reference evaluation" $ do
      evaluateBool 64 [] (Binary "&&" (BoolLit False) (Binary ">" (Binary "/" (Number 1) (Number 0)) (Number 0))) `shouldBe` Right False
      evaluateBool 64 [] (Binary "||" (BoolLit True) (Binary ">" (Binary "/" (Number 1) (Number 0)) (Number 0))) `shouldBe` Right True
      evaluateBool 64 [] (Binary ">" (Binary "/" (Number 1) (Number 0)) (Number 0)) `shouldSatisfy` isLeft
    it "resolves machine bounds from the requested profile" $ do
      boundsValue 32 "max" (Named "IntSize") `shouldBe` Right (SInteger "Integer" 2147483647)
      boundsValue 64 "max" (Named "IntSize") `shouldBe` Right (SInteger "Integer" 9223372036854775807)
    it "rejects invalid generation limits" $
      compileWithSettings 64 defaultGeneration{maxAttempts=0} [spec (law "(x :: Int8)" "x = x")] `shouldSatisfy` isLeft

    it "avoids capturing a value argument with an alias's own binder" $ do
      let header = "refinement GreaterThan (T :: Type) (lower :: T) requires Ordered T is (x :: T where x > lower) end\n"
          body = "law `dependent` is definition is `for all` (x :: Int8) (y :: GreaterThan Int8 x) . y > x end example `valid` is x = 0 y = 1 expect y = 1 end end"
      compile [spec (header ++ body)] `shouldSatisfy` isRight
    it "rejects capability mismatches in refined results" $
      compile [spec "refinement Positive (T :: Type) requires Integer T is (x :: T where x > 0) end\nf :: Int8 -> Positive Float64"] `shouldSatisfy` isLeft

    it "enforces refinements on named refinement value parameters" $ do
      let header = "refinement Positive is (x :: Int8 where x > 0) end\nrefinement Above (lower :: Positive) is (value :: Int8 where value > lower) end\n"
      compile [spec (header ++ law "(x :: Above (-1))" "x = x")] `shouldSatisfy` isLeft
      compile [spec (header ++ law "(x :: Above 1)" "x = x")] `shouldSatisfy` isRight

    it "evaluates complex equality and negation in pure predicates" $ do
      let z = SComplex "Complex64" (floatScalar "Float32" 1) (floatScalar "Float32" 2)
          negative = SComplex "Complex64" (floatScalar "Float32" (-1)) (floatScalar "Float32" (-2))
      evaluateBool 64 [] (Binary "==" (ScalarLit z) (ScalarLit z)) `shouldBe` Right True
      evaluateBool 64 [] (Binary "!=" (ScalarLit z) (ScalarLit negative)) `shouldBe` Right True
      evaluate 64 [] (Unary "-" (ScalarLit z)) `shouldBe` Right negative
