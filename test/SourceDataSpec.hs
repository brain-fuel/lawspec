module SourceDataSpec (spec) where

import Test.Hspec
import qualified LawSpec.Public as Public
import qualified LawSpec.Model as S
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Either (isLeft, isRight)
import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Core
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..))
import LawSpec.Testing (planTesting, plannedUnits, plannedProperties, finiteCases)
import LawSpec.CoreEmit (emitPlan, targets)
import Data.List (isInfixOf)

check :: String -> Either [Diagnostic] Program
check body = compileCore 64 defaultGeneration [Source "source-data" ("unit data_test\n" ++ body)]
law :: String -> String -> String
law ty expression = "law `test` is definition is `for all` (x :: " ++ ty ++ ") . " ++ expression ++ " end end"

spec :: Spec
spec = describe "source algebraic data" $ do
  it "lowers named type argument refinements through products, sums, and nested fields" $ do
    let declarations = unlines
          ["type Box (a :: Type) is Box value :: a end"
          ,"type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end"
          ,"type Choice (a :: Type) (b :: Type) is First value :: a | Second value :: b end"
          ,"type Nest (a :: Type) is Nest value :: Box (Maybe (List a)) end"
          ,"refinement Positive is (x :: Int8 where x > 0) end"]
        source ty value = declarations ++ "copy :: " ++ ty ++ " -> " ++ ty ++ "\n" ++
          "law `payload` is definition is `for all` (x :: " ++ ty ++ ") . copy x = x end " ++
          "example `value` is x = " ++ value ++ " expect copy x = " ++ value ++ " end end"
    forM_ [("Box Positive","Box 1","Box 0"),
           ("Pair Positive Int8","Pair 1 -128","Pair 0 -128"),
           ("Choice Positive Bool","First 1","First 0"),
           ("Nest Positive","Nest (Box (Just [1, 2]))","Nest (Box (Just [1, 0]))")] $
      \(ty,valid,invalid) -> do
        case check (source ty valid) >>= planTesting of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
        check (source ty invalid) `shouldSatisfy` isLeft
    check (source "Choice Positive Bool" "Second false") `shouldSatisfy` isRight
    check (source "Nest Positive" "Nest (Box Nothing)") `shouldSatisfy` isRight
  it "enumerates named refined payloads and preserves outer dependencies" $ do
    let declarations = "type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end\n"
        finite = declarations ++ law "Pair (flag :: Bool where flag) Bool" "x = x"
    case check finite >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> map (fmap length . finiteCases)
        (concatMap plannedProperties (plannedUnits plan)) `shouldBe` [Just 2]
    let source value = declarations ++
          "law `dependent` is definition is `for all` (lawspecElement :: Int8) " ++
          "(x :: Pair (v :: Int8 where v > lawspecElement) Bool) . x = x end " ++
          "example `bound` is lawspecElement = 4 x = Pair " ++ value ++
          " true expect x = Pair " ++ value ++ " true end end"
    check (source "5") `shouldSatisfy` isRight
    check (source "4") `shouldSatisfy` isLeft
  it "keeps named type argument dependencies outside the constructor field scope" $ do
    let source value = "type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end\n" ++
          "law `scope` is definition is `for all` (first :: Int8) " ++
          "(x :: Pair Int8 (v :: Int8 where v > first)) . x = x end " ++
          "example `outer bound` is first = 4 x = Pair -128 " ++ value ++
          " expect x = Pair -128 " ++ value ++ " end end"
    check (source "5") `shouldSatisfy` isRight
    check (source "0") `shouldSatisfy` isLeft
  it "proves constructed named payload contracts without synthetic binder collisions" $ do
    let source = unlines
          ["type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end"
          ,"refinement Positive is (x :: Int8 where x > 0) end"
          ,"choose :: Pair Positive Bool -> Pair Positive Bool -> Pair Positive Bool"
          ,"definition build (x :: Positive) :: Pair Positive Bool is Pair x true end"
          ,"definition copy (x :: Pair Positive Bool) :: Pair Positive Bool is x end"
          ,"law `build` is definition is `for all` (x :: Positive) . copy (build x) = Pair x true end"
          ,"example `positive` is x = 1 expect copy (build x) = Pair 1 true end end"]
    case check source >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "checks recursive named payloads without constraining fixed fields" $ do
    let source value = unlines
          ["type Tree (a :: Type) is Leaf value :: a fixed :: Int8 | Branch children :: List (Tree a) end"
          ,"refinement Positive is (value :: Int8 where value > 0) end"
          ,"law `recursive` is definition is `for all` (x :: Tree Positive) . x = x end"
          ,"example `tree` is x = " ++ value ++ " expect x = " ++ value ++ " end end"]
    forM_ ["Branch []", "Branch [Leaf 1 -128, Branch [Leaf 2 0]]"] $ \value ->
      case check (source value) >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> forM_ targets $ \target ->
          emitPlan target plan `shouldSatisfy` isRight
    check (source "Branch [Leaf 1 0, Branch [Leaf 0 -128]]")
      `shouldSatisfy` isLeft
  it "preserves recursive parameter roles through mutual and growing types" $ do
    let source ty value = unlines
          ["type A (a :: Type) (b :: Type) is EndA value :: a | NextA child :: B b a end"
          ,"type B (a :: Type) (b :: Type) is EndB value :: a | NextB child :: A b a end"
          ,"type Nest (a :: Type) is Stop value :: a | Next child :: Nest (List a) end"
          ,"refinement Positive is (v :: Int8 where v > 0) end"
          ,"refinement Negative is (v :: Int8 where v < 0) end"
          ,"law `roles` is definition is `for all` (x :: " ++ ty ++ ") . x = x end"
          ,"example `value` is x = " ++ value ++ " expect x = " ++ value ++ " end end"]
    forM_ [("A Positive Negative", "NextA (EndB -1)", "NextA (EndB 1)"),
           ("Nest Positive", "Next (Stop [1, 2])", "Next (Stop [1, 0])")] $
      \(ty,valid,invalid) -> do
        check (source ty valid) `shouldSatisfy` isRight
        check (source ty invalid) `shouldSatisfy` isLeft
  it "proves recursive definitions from refined stored parameters at both widths" $ do
    source <- readFile "examples/specs/recursive_refinements.lawspec"
    forM_ [32,64] $ \bits -> case
      compileCore bits defaultGeneration [Source "recursive-refinements" source]
        >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target ->
        emitPlan target plan `shouldSatisfy` isRight
  it "composes named product predicates with ordered dependent fields" $ do
    let int8 = S.Named "Int8"
        lower = S.Refined "x" int8 (Just (S.Binary ">" (S.Var "x") (S.Var "lawspecElement")))
        upper = S.Refined "x" int8 (Just (S.Binary ">" (S.Var "x") (S.Var "lower")))
        [predicate] = S.constructorPredicates (S.Var "range")
          [("Empty",[]),("Range",[("lower",lower),("upper",upper)])]
        source input = "type Range is Empty | Range lower :: Int8 upper :: Int8 end\n" ++
          "law `range` is definition is `for all` (lawspecElement :: Int8) " ++
          "(range :: Range where " ++ S.prettyExpr predicate ++ ") . range = range end " ++
          "example `bounds` is lawspecElement = 4 range = " ++ input ++
          " expect range = " ++ input ++ " end end"
    forM_ ["Empty","Range 5 6"] $ \value -> case check (source value) >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
    forM_ ["Range 4 6","Range 5 5","Range 6 5"] $ \value ->
      check (source value) `shouldSatisfy` isLeft
    S.exprVars predicate `shouldBe` ["range","lawspecElement"]
  it "short-circuits product constraints before partial later-field predicates" $ do
    let int8 = S.Named "Int8"
        lower = S.Refined "x" int8 (Just (S.Binary "!=" (S.Var "x") (S.Number 0)))
        upper = S.Refined "x" int8 (Just (S.Binary ">"
          (S.Binary "/" (S.Number 1) (S.Var "lower")) (S.Number 0)))
        [predicate] = S.constructorPredicates (S.Var "range")
          [("Range",[("lower",lower),("upper",upper)])]
        source value = "type Range is Range lower :: Int8 upper :: Int8 end\n" ++
          "law `guard` is definition is `for all` (range :: Range where " ++
          S.prettyExpr predicate ++ ") . range = range end example `zero` is " ++
          "range = Range " ++ value ++ " 7 expect range = Range " ++ value ++ " 7 end end"
    check (source "1") `shouldSatisfy` isRight
    case check (source "0") of
      Right _ -> expectationFailure "accepted an invalid earlier field"
      Left diagnostics -> show diagnostics `shouldNotSatisfy` isInfixOf "division by zero"
  it "does not invent predicates for unconstrained constructor fields" $
    S.constructorPredicates (S.Var "value")
      [("Empty",[]),("Pair",[("first",S.Named "Int8"),("second",S.Named "Bool")])]
      `shouldBe` []
  it "checks nested List payload refinements and emits all targets" $ do
    let source ty input = "law `payload` is definition is `for all` (x :: " ++ ty ++ ") . x = x end " ++
          "example `value` is x = " ++ input ++ " expect x = " ++ input ++ " end end"
    forM_ [("List (value :: Int8 where value > 0)","[1, 127]","[1, 0]"),
           ("List (List (value :: Int8 where value > 0))","[[], [1]]","[[0]]"),
           ("List (Maybe (value :: Int8 where value > 0))","[Nothing, Just 1]","[Just 0]"),
           ("Maybe (List (value :: Int8 where value > 0))","Just [1]","Just [0]")] $ \(ty,valid,invalid) -> do
      case check (source ty valid) >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
      check (source ty invalid) `shouldSatisfy` isLeft
    check (source "List (value :: Int8 where value > 0)" "[]") `shouldSatisfy` isRight
  it "serializes scoped List predicates in the public Core view" $ do
    case check (law "List (value :: Int8 where value > 0)" "x = x") of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let encoded = BL.unpack (A.encode (Public.programView defaultGeneration [] [] [] [] program))
        encoded `shouldSatisfy` isInfixOf "allElements"
        encoded `shouldSatisfy` isInfixOf "predicate"
  it "keeps dependent List payload binders fresh" $ do
    let source input = "law `dependent` is definition is `for all` (lawspecElement :: Int8) " ++
          "(x :: List (value :: Int8 where value > lawspecElement)) . x = x end " ++
          "example `value` is lawspecElement = 0 x = " ++ input ++ " expect x = " ++ input ++ " end end"
    check (source "[1, 2]") `shouldSatisfy` isRight
    check (source "[1, 0]") `shouldSatisfy` isLeft
    check (source "[]") `shouldSatisfy` isRight
  it "checks Maybe and Either payload refinements and emits all targets" $ do
    let source ty input = "law `payload` is definition is `for all` (x :: " ++ ty ++ ") . x = x end " ++
          "example `value` is x = " ++ input ++ " expect x = " ++ input ++ " end end"
    forM_ [("Maybe (value :: Int8 where value > 0)","Just 1","Just 0"),
           ("Either (value :: Int8 where value > 0) Bool","Left 1","Left 0"),
           ("Either Bool (value :: Int8 where value > 0)","Right 1","Right 0"),
           ("Maybe (Maybe (value :: Int8 where value > 0))","Just (Just 1)","Just (Just 0)")] $ \(ty,valid,invalid) -> do
      case check (source ty valid) >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
      check (source ty invalid) `shouldSatisfy` isLeft
    check (source "Maybe (value :: Int8 where value > 0)" "Nothing") `shouldSatisfy` isRight
    check (source "Either (value :: Int8 where value > 0) Bool" "Right true") `shouldSatisfy` isRight
  it "keeps synthesized sum tags distinct from user constructors with the same spelling" $ do
    let declaration = "type Names is Nothing | Just payload :: Int8 | Left flag :: Bool | Right end\n"
        signatures = "maybeEcho :: Maybe (value :: Int8 where value > 0) -> Maybe Int8\n" ++
          "eitherEcho :: Either (value :: Int8 where value > 0) Bool -> Either Int8 Bool\n"
    case check (declaration ++ signatures) >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "enumerates finite refined sum domains without collapsing absence or variants" $ do
    forM_ [("Maybe (value :: Bool where value)",2),
           ("Either (value :: Bool where value) (value :: Bool where !value)",2),
           ("Maybe (Maybe (value :: Bool where value))",3)] $ \(ty,count) ->
      case check (law ty "x = x") >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> map (fmap length . finiteCases) (concatMap plannedProperties (plannedUnits plan))
          `shouldBe` [Just count]
  it "rejects unchecked refinement-bearing expression annotations" $ do
    forM_ ["(0 :: (n :: Int8 where n > 0))",
           "(Box 0 :: Box (n :: Int8 where n > 0))"] $ \expression ->
      case check ("type Box (a :: Type) is Box value :: a end\n" ++
        law "Unit" (expression ++ " = " ++ expression)) of
        Right _ -> expectationFailure "silently erased an annotation predicate"
        Left diagnostics -> show diagnostics `shouldSatisfy` isInfixOf "expression annotations"
  describe "source constructor field contracts" $ do
    let positive = "type Box is Box value :: (n :: Int8 where n > 0) end\n"
        reciprocal = "definition reciprocal (box :: Box) :: Rational is " ++
          "match box with | Box n -> 1 / n end end"
        source datatype definition = check (datatype ++ definition)
    it "retains source predicates and proves pattern-dependent total definitions" $ do
      case source positive reciprocal of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right program -> do
          map (length . constructorPredicates) (concatMap dataConstructors (programDataDeclarations program))
            `shouldBe` [1]
          case prepareDefinitions program of
            Left diagnostics -> expectationFailure (show diagnostics)
            Right invoke -> do
              let ty = scalarType "data_test::type::Box"
                  boxed n = DataValue ty (Id "data_test::type::Box::Box") [ScalarValue (SInteger "Int8" n)]
              invoke (Id "data_test::reciprocal") [boxed 2] `shouldBe` Right (ScalarValue (SRational 1 2))
              invoke (Id "data_test::reciprocal") [boxed 0] `shouldSatisfy` isLeft
          planTesting program `shouldSatisfy` isRight
    it "proves constructor obligations in source definitions" $ do
      let make n = "definition make (unused :: Unit) :: Box is Box " ++ n ++ " end"
      source positive (make "1") `shouldSatisfy` isRight
      source positive (make "0") `shouldSatisfy` isLeft
    it "resolves earlier field dependencies and rejects later fields" $ do
      source "type Gap is Gap first :: Int8 second :: (n :: Int8 where n > first) end\n"
        ("definition inverse (gap :: Gap) :: Rational is " ++
         "match gap with | Gap x y -> 1 / (y - x) end end") `shouldSatisfy` isRight
      check "type Gap is Gap first :: (n :: Int8 where n > second) second :: Int8 end"
        `shouldSatisfy` isLeft
    it "checks alias requirements and unused malformed declarations" $ do
      check ("refinement Positive (T :: Type) requires Integer T is (n :: T where n > 0) end\n" ++
        "type Box is Box value :: Positive Int8 end") `shouldSatisfy` isRight
      check "type Box is Box value :: (n :: Int8 where n + 1) end" `shouldSatisfy` isLeft
      check "type Box is Box value :: (n :: Int8 where 1 / n > 0) end" `shouldSatisfy` isLeft
      check "type Box is Box value :: (n :: Int8 where n > missing) end" `shouldSatisfy` isLeft
    it "rejects concrete invalid example inputs and expected constructors" $ do
      let example input output = positive ++ law "Box" "x = x" ++
            "\nlaw `example` is definition is `for all` (x :: Box) . x = x end " ++
            "example `one` is x = Box " ++ input ++ " expect x = Box " ++ output ++ " end end"
      check (example "1" "1") `shouldSatisfy` isRight
      check (example "0" "1") `shouldSatisfy` isLeft
      check (example "1" "0") `shouldSatisfy` isLeft
    it "plans exhaustive source laws over finite field contracts" $ do
      let source predicate = "type Flag is Flag value :: (b :: Bool where " ++ predicate ++ ") end\n" ++
            law "Flag" "x = x"
      case check (source "b") >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> do
          let cases = [finiteCases p | u <- plannedUnits plan, p <- plannedProperties u]
          map (fmap length) cases `shouldBe` [Just 1]
      case check (source "false") >>= planTesting of
        Right _ -> expectationFailure "invented a value for an empty field domain"
        Left diagnostics -> show diagnostics `shouldSatisfy` isInfixOf "no valid tuples"
    it "threads machine width through constructor predicate admission" $ do
      let content = "unit width\ntype Box is Box value :: (n :: IntSize where " ++
            "prelude.Int32 n == prelude.Int32 n) end"
          result bits = compileCore bits defaultGeneration [Source "width.lawspec" content]
      result 32 `shouldSatisfy` isRight
      result 64 `shouldSatisfy` isLeft
    it "preserves generic field identities and nested predicates" $ do
      check ("type Box (a :: Type) is Box value :: a count :: (n :: Int8 where n > 0) end\n" ++
        "definition first (box :: Box Int8) :: Int8 is match box with | Box x count -> x end end")
        `shouldSatisfy` isRight
      check "type Box is Box values :: List (n :: Int8 where n > 0) end" `shouldSatisfy` isRight
  it "retains named payload predicates in checked Core" $ do
    case check ("type Box (a :: Type) is Box value :: a end\n" ++
      law "Box (value :: Int8 where value > 0)" "x = x") of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let inputs = concat [propertyInputs property | unit <- programUnits program,
              property <- unitProperties unit]
        map (null . quantifiedPredicates) inputs `shouldBe` [False]
  it "does not capture outer dependencies when lowering sum payload refinements" $ do
    let source value = "law `dependent` is definition is `for all` (lawspecElement :: Int8) " ++
          "(x :: Maybe (value :: Int8 where value > lawspecElement)) . x = x end " ++
          "example `value` is lawspecElement = 0 x = Just " ++ value ++ " expect x = Just " ++ value ++ " end end"
    check (source "1") `shouldSatisfy` isRight
    check (source "0") `shouldSatisfy` isLeft
  forM_ [
      ("recursive products and sums", "type Tree (a :: Type) is Leaf value :: a | Branch children :: List (Tree a) end\n" ++ law "Tree Int8" "x = x"),
      ("forward references", "type A is A value :: B end\ntype B is B end\n" ++ law "A" "x = x"),
      ("two type arguments", law "Either (List Int8) (Maybe Bool)" "x = x"),
      ("nested list contexts", law "List (List Int8)" "x = [[], [127]]"),
      ("literal equality from the left", law "List Int8" "[127, -128] = x"),
      ("algebraic nested absence", law "Maybe (Maybe Bool)" "x = Just Nothing"),
      ("Either contextual payload", law "Either Int8 Bool" "x = Left 127"),
      ("complementary constructor contexts", law "Bool" "(Left (127 :: Int8)) = (Right true)"),
      ("list length", law "List Int8" "prelude.length x >= 0"),
      ("exhaustive matching", law "Maybe Bool" "(match x with | Nothing -> false | Just payload -> payload end) = true"),
      ("nested local matching", law "Maybe (Maybe Bool)" "(match x with | Nothing -> false | Just x -> match x with | Nothing -> false | Just x -> x end end) = true"),
      ("product matching", "type Pair (a :: Type) is Pair first :: a second :: Bool end\n" ++ law "Pair Int8" "(match x with | Pair first second -> Pair first second end) = x")
    ] $ \(label,source) -> it ("accepts " ++ label) $ check source `shouldSatisfy` isRight
  forM_ [
      ("unbound data parameters", "type Box is Box value :: a end"),
      ("unknown field types", "type Box is Box value :: Missing end"),
      ("unsaturated applications", law "Either Int8" "x = x"),
      ("excess type arguments", law "Maybe Bool Bool" "x = x"),
      ("duplicate declarations", "type Box is B end\ntype Box is C end"),
      ("duplicate fields", "type Box is B value :: Bool value :: Bool end"),
      ("duplicate parameters", "type Box (a :: Type) (a :: Type) is B end"),
      ("negative recursion", "type Bad is Bad value :: (Bad -> Bool) end"),
      ("range-invalid list elements", law "List Int8" "x = [128]"),
      ("heterogeneous list elements", law "List Int8" "x = [1, true]"),
      ("constructor payload mismatch", law "Maybe Bool" "x = Just 127"),
      ("missing constructor argument", law "Maybe Bool" "x = Just"),
      ("extra constructor argument", law "Maybe Bool" "x = Nothing true"),
      ("foreign constructors", law "Maybe Bool" "x = Left true"),
      ("incomplete match", law "Maybe Bool" "(match x with | Nothing -> false end) = true"),
      ("duplicate match branch", law "Maybe Bool" "(match x with | Nothing -> false | Nothing -> true | Just p -> p end) = true"),
      ("escaping branch binder", law "Maybe Bool" "(match x with | Nothing -> p | Just p -> p end) = true"),
      ("inconsistent branch results", law "Maybe Bool" "(match x with | Nothing -> 1 | Just p -> p end) = true"),
      ("collection arithmetic", law "List Int8" "x + x = x"),
      ("collection presence operations", law "List Bool" "prelude.isPresent x"),
      ("missing generic Eq evidence", "law `generic` (f :: List a -> List a) is definition is `for all` (x :: List a) . f x = x end end")
    ] $ \(label,source) -> it ("rejects " ++ label) $ check source `shouldSatisfy` isLeft
  it "checks example refinements against concrete lists" $ do
    let source xs = "law `nonempty` is definition is `for all` (x :: List Int8 where prelude.length x > 0) . x = x end example `fixture` is x = " ++ xs ++ " expect x = " ++ xs ++ " end end"
    check (source "[1]") `shouldSatisfy` isRight
    check (source "[]") `shouldSatisfy` isLeft
  it "checks uninhabited data separately from execution feasibility" $ do
    case check ("type Empty is end\n" ++ law "Empty" "x = x") of
      Left ds -> expectationFailure (show ds)
      Right program -> planTesting program `shouldSatisfy` isLeft

  it "emits checked native Haskell products and recursive sums" $ do
    let source = "type Tree (a :: Type) is Leaf value :: a | Branch children :: List (Tree a) end\n" ++
          "echo :: Tree Int8 -> Tree Int8\n" ++ law "Tree Int8" "echo x = x"
    case check source >>= planTesting >>= emitPlan "haskell" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let contents = concatMap artifactContent files
        contents `shouldSatisfy` isInfixOf "echo :: (Data.Tree I.Int8) -> (Data.Tree I.Int8)"
        contents `shouldSatisfy` isInfixOf "Codec.decode"
        contents `shouldSatisfy` isInfixOf "Strategies.strategy"
        contents `shouldSatisfy` isInfixOf "Schema.validate"
  it "rejects Haskell support-module path collisions before output" $ do
    let source = Source "collision" "unit lawSpecData\necho :: Bool -> Bool"
    (compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "haskell")
      `shouldSatisfy` isLeft

  it "emits checked native Kotlin recursive adapters and Kotest generators" $ do
    let source = "type Tree (a :: Type) is Leaf value :: a | Branch children :: List (Tree a) end\n" ++
          "echo :: Tree Int8 -> Tree Int8\n" ++ law "Tree Int8" "echo x = x"
    case check source >>= planTesting >>= emitPlan "kotlin" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let contents = concatMap artifactContent files
        contents `shouldSatisfy` isInfixOf "value0: lawspec.data.Tree<kotlin.Byte>"
        contents `shouldSatisfy` isInfixOf "LawSpecKotlinStrategies.generator"
        contents `shouldSatisfy` isInfixOf "LawSpecDataCodecs.treeCodec"
        contents `shouldSatisfy` isInfixOf "_schema.validate"

  it "rejects Kotlin adapters that shadow JVM runtime classes" $ do
    forM_ ["lawspec.runtime.law_spec_schema", "kotlin.example"] $ \unit -> do
      let source = Source "collision" ("unit " ++ unit ++ "\necho :: Bool -> Bool")
      (compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "kotlin")
        `shouldSatisfy` isLeft
