-- | Refinements of source algebraic data.
module SourceDataSpec (test_sourceDataRefinementsLowerThroughNestedTypes) where

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
check body = compileCore 64 defaultGeneration [Source "source-data" ("unit data_test\n\n" ++ body ++ "\nend unit\n")]
law :: String -> String -> String
law ty expression = "law \"|test| is definition: for all (x :: " ++ ty ++ ") => " ++ expression ++ " end for all end definition end law\n"

-- | A refinement written on a type argument constrains the values stored deep
-- inside a structure, so it must reach every field it names and nothing else.
-- ref:DEC-total-definitions ref:REQ-source-data-refinements
test_sourceDataRefinementsLowerThroughNestedTypes :: Spec
test_sourceDataRefinementsLowerThroughNestedTypes = describe "source algebraic data" $ do
  it "lowers named type argument refinements through products, sums, and nested fields" $ do
    let declarations = unlines
          [ "type Box (a :: Type) is a record{  value :: a} end type\n"
          , "type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type\n"
          , "type Choice (a :: Type) (b :: Type) is one of First  of type a | Second  of type b end type\n"
          , "type Nest (a :: Type) is a record{  value :: Box (Maybe (List a))} end type"
          , "refinement Positive is (x :: Int8 where x > 0) end refinement" ]
        source ty value = declarations ++ "copy :: " ++ ty ++ " -> " ++ ty ++ "\n" ++
          "law \"|payload| is definition: for all (x :: " ++ ty ++ ") => copy x = x end for all end definition " ++
          "example \"|value| : x = " ++ value ++ " expect copy x = " ++ value ++ " end example end law\n"
    forM_ [("Box Positive","Box 1","Box 0"),
           ("Pair Positive Int8","Pair 1 -128","Pair 0 -128"),
           ("Choice Positive Bool","First 1","First 0"),
           ("Nest Positive","Nest (Box (Present [1, 2]))","Nest (Box (Present [1, 0]))")] $
      \(ty,valid,invalid) -> do
        case check (source ty valid) >>= planTesting of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
        check (source ty invalid) `shouldSatisfy` isLeft
    check (source "Choice Positive Bool" "Second false") `shouldSatisfy` isRight
    check (source "Nest Positive" "Nest (Box Absent)") `shouldSatisfy` isRight
  it "enumerates named refined payloads and preserves outer dependencies" $ do
    let declarations = "type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type\n"
        finite = declarations ++ law "Pair (flag :: Bool where flag) Bool" "x = x"
    case check finite >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> map (fmap length . finiteCases)
        (concatMap plannedProperties (plannedUnits plan)) `shouldBe` [Just 2]
    let source value = declarations ++
          "law \"|dependent| is definition : for all (lawspecElement :: Int8) " ++
          "(x :: Pair (v :: Int8 where v > lawspecElement) Bool) => x = x end for all end definition " ++
          "example \"|bound| : lawspecElement = 4 x = Pair record{ first = " ++ value ++
          " , second = true} expect x = Pair record{ first = " ++ value ++ " , second = true} end example end law\n"
    check (source "5") `shouldSatisfy` isRight
    check (source "4") `shouldSatisfy` isLeft
  it "keeps named type argument dependencies outside the constructor field scope" $ do
    let source value = "type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type\n" ++
          "law \"|scope| is definition: for all (first :: Int8) " ++
          "(x :: Pair Int8 (v :: Int8 where v > first)) => x = x end for all end definition " ++
          "example \"|outer bound| : first = 4 x = Pair -128 " ++ value ++
          " expect x = Pair -128 " ++ value ++ " end example end law"
    check (source "5") `shouldSatisfy` isRight
    check (source "0") `shouldSatisfy` isLeft
  it "proves constructed named payload contracts without synthetic binder collisions" $ do
    let source = unlines
          [ "type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type\n"
          , "refinement Positive is (x :: Int8 where x > 0) end refinement"
          , "choose :: Pair Positive Bool -> Pair Positive Bool -> Pair Positive Bool"
          , "function build (x :: Positive) -> Pair Positive Bool is Pair record{ first = x , second = true} end function\n"
          , "function copy (x :: Pair Positive Bool) -> Pair Positive Bool is x end function\n"
          , "law \"|build| is definition : for all (x :: Positive) => copy (build x) = Pair record{ first = x , second = true} end for all end definition"
          , "example \"|positive| : x = 1 expect copy (build x) = Pair record{ first = 1 , second = true} end example end law" ]
    case check source >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "checks recursive named payloads without constraining fixed fields" $ do
    let source value = unlines
          ["type Tree (a :: Type) is one of Leaf of type record{ value :: a fixed :: Int8} | Branch  of type List (Tree a) end type\n"
          ,"refinement Positive is (value :: Int8 where value > 0) end refinement\n"
          ,"law \"|recursive| is definition: for all (x :: Tree Positive) => x = x end for all end definition"
          ,"example \"|tree| : x = " ++ value ++ " expect x = " ++ value ++ " end example end law"]
    forM_ ["Branch []", "Branch [Leaf record{value = 1, fixed = -128}, Branch [Leaf record{value = 2, fixed = 0}]]"] $ \value ->
      case check (source value) >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> forM_ targets $ \target ->
          emitPlan target plan `shouldSatisfy` isRight
    check (source "Branch [Leaf record{value = 1, fixed = 0}, Branch [Leaf record{value = 0, fixed = -128}]]")
      `shouldSatisfy` isLeft
  it "preserves recursive parameter roles through mutual and growing types" $ do
    let source ty value = unlines
          ["type A (a :: Type) (b :: Type) is one of EndA of type a | NextA of type B b a end type"
          ,"type B (a :: Type) (b :: Type) is one of EndB of type a | NextB of type A b a end type"
          ,"type Nest (a :: Type) is one of Stop  of type a | Next  of type Nest (List a) end type\n"
          ,"refinement Positive is (v :: Int8 where v > 0) end refinement\n"
          ,"refinement Negative is (v :: Int8 where v < 0) end refinement\n"
          ,"law \"|roles| is definition: for all (x :: " ++ ty ++ ") => x = x end for all end definition"
          ,"example \"|value| : x = " ++ value ++ " expect x = " ++ value ++ " end example end law"]
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
        [fieldsPredicate] = S.constructorPredicates (S.Var "fields")
          [("RangeFields",[("lower",lower),("upper",upper)])]
        predicate = S.MatchExpr (S.Var "range")
          [S.MatchBranch "Empty" [] (S.BoolLit True), S.MatchBranch "Range" ["fields"] fieldsPredicate]
        source input = "type RangeFields is a record{lower :: Int8 upper :: Int8} end type\ntype Range is one of Empty | Range of type RangeFields end type\n" ++
          "law \"|range| is definition: for all (lawspecElement :: Int8) " ++
          "(range :: Range where " ++ S.prettyExpr predicate ++ ") => range = range end for all end definition " ++
          "example \"|bounds| : lawspecElement = 4 range = " ++ input ++
          " expect range = " ++ input ++ " end example end law"
    forM_ ["Empty","Range (RangeFields 5 6)"] $ \value -> case check (source value) >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
    forM_ ["Range (RangeFields 4 6)","Range (RangeFields 5 5)","Range (RangeFields 6 5)"] $ \value ->
      check (source value) `shouldSatisfy` isLeft
    S.exprVars predicate `shouldBe` ["range","lawspecElement"]
  it "short-circuits product constraints before partial later-field predicates" $ do
    let int8 = S.Named "Int8"
        lower = S.Refined "x" int8 (Just (S.Binary "!=" (S.Var "x") (S.Number 0)))
        upper = S.Refined "x" int8 (Just (S.Binary ">"
          (S.Binary "/" (S.Number 1) (S.Var "lower")) (S.Number 0)))
        [predicate] = S.constructorPredicates (S.Var "range")
          [("Range",[("lower",lower),("upper",upper)])]
        source value = "type Range is a record{  lower :: Int8 upper :: Int8} end type\n" ++
          "law \"|guard| is definition: for all (range :: Range where " ++
          S.prettyExpr predicate ++ ") => range = range end for all end definition example \"|zero| : " ++
          "range = Range " ++ value ++ " 7 expect range = Range " ++ value ++ " 7 end example end law"
    check (source "1") `shouldSatisfy` isRight
    case check (source "0") of
      Right _ -> expectationFailure "accepted an invalid earlier field"
      Left diagnostics -> show diagnostics `shouldNotSatisfy` isInfixOf "division by zero"
  it "does not invent predicates for unconstrained constructor fields" $
    S.constructorPredicates (S.Var "value")
      [("Empty",[]),("Pair",[("first",S.Named "Int8"),("second",S.Named "Bool")])]
      `shouldBe` []
  it "checks nested List payload refinements and emits all targets" $ do
    let source ty input = "law \"|payload| is definition: for all (x :: " ++ ty ++ ") => x = x end for all end definition " ++
          "example \"|value| : x = " ++ input ++ " expect x = " ++ input ++ " end example end law"
    forM_ [("List (value :: Int8 where value > 0)","[1, 127]","[1, 0]"),
           ("List (List (value :: Int8 where value > 0))","[[], [1]]","[[0]]"),
           ("List (Maybe (value :: Int8 where value > 0))","[Absent, Present 1]","[Present 0]"),
           ("Maybe (List (value :: Int8 where value > 0))","Present [1]","Present [0]")] $ \(ty,valid,invalid) -> do
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
    let source input = "law \"|dependent| is definition: for all (lawspecElement :: Int8) " ++
          "(x :: List (value :: Int8 where value > lawspecElement)) => x = x end for all end definition " ++
          "example \"|value| : lawspecElement = 0 x = " ++ input ++ " expect x = " ++ input ++ " end example end law"
    check (source "[1, 2]") `shouldSatisfy` isRight
    check (source "[1, 0]") `shouldSatisfy` isLeft
    check (source "[]") `shouldSatisfy` isRight
  it "checks Maybe and Either payload refinements and emits all targets" $ do
    let source ty input = "law \"|payload| is definition: for all (x :: " ++ ty ++ ") => x = x end for all end definition " ++
          "example \"|value| : x = " ++ input ++ " expect x = " ++ input ++ " end example end law"
    forM_ [("Maybe (value :: Int8 where value > 0)","Present 1","Present 0"),
           ("Either (value :: Int8 where value > 0) Bool","Left 1","Left 0"),
           ("Either Bool (value :: Int8 where value > 0)","Right 1","Right 0"),
           ("Maybe (Maybe (value :: Int8 where value > 0))","Present (Present 1)","Present (Present 0)")] $ \(ty,valid,invalid) -> do
      case check (source ty valid) >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
      check (source ty invalid) `shouldSatisfy` isLeft
    check (source "Maybe (value :: Int8 where value > 0)" "Absent") `shouldSatisfy` isRight
    check (source "Either (value :: Int8 where value > 0) Bool" "Right true") `shouldSatisfy` isRight
  it "keeps synthesized sum tags distinct from user constructors with the same spelling" $ do
    let declaration = "type Names is one of Absent | Present  of type Int8 | Left  of type Bool | Right end type\n"
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
      case check ("type Box (a :: Type) is a record{  value :: a} end type\n" ++
        law "Unit" (expression ++ " = " ++ expression)) of
        Right _ -> expectationFailure "silently erased an annotation predicate"
        Left diagnostics -> show diagnostics `shouldSatisfy` isInfixOf "expression annotations"
  describe "source constructor field contracts" $ do
    let positive = "type Box is a record{  value :: (n :: Int8 where n > 0)} end type\n"
        reciprocal = "function reciprocal (box :: Box) -> Rational is " ++
          "first matching case of box : when Box n then 1 / n end case end function\n"
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
      let make n = "function make (unused :: Unit) -> Box is Box " ++ n ++ " end function\n"
      source positive (make "1") `shouldSatisfy` isRight
      source positive (make "0") `shouldSatisfy` isLeft
    it "resolves earlier field dependencies and rejects later fields" $ do
      source "type Gap is a record{  first :: Int8 second :: (n :: Int8 where n > first)} end type\n"
        ("function inverse (gap :: Gap) -> Rational is " ++
         "first matching case of gap : when Gap x y then 1 / (y - x) end case end function\n") `shouldSatisfy` isRight
      check "type Gap is a record{  first :: (n :: Int8 where n > second) second :: Int8} end type\n"
        `shouldSatisfy` isLeft
    it "checks alias requirements and unused malformed declarations" $ do
      check ("refinement Positive (T :: Type) requires Integer T is (n :: T where n > 0) end refinement\n" ++
        "type Box is one of Box  of type Positive Int8 end type\n") `shouldSatisfy` isRight
      check "type Box is a record{  value :: (n :: Int8 where n + 1)} end type\n" `shouldSatisfy` isLeft
      check "type Box is a record{  value :: (n :: Int8 where 1 / n > 0)} end type\n" `shouldSatisfy` isLeft
      check "type Box is a record{  value :: (n :: Int8 where n > missing)} end type\n" `shouldSatisfy` isLeft
    it "rejects concrete invalid example inputs and expected constructors" $ do
      let example input output = positive ++ law "Box" "x = x" ++
            "\nlaw \"|example| is definition: for all (x :: Box) => x = x end for all end definition " ++
            "example \"|one| : x = Box " ++ input ++ " expect x = Box " ++ output ++ " end example end law"
      check (example "1" "1") `shouldSatisfy` isRight
      check (example "0" "1") `shouldSatisfy` isLeft
      check (example "1" "0") `shouldSatisfy` isLeft
    it "plans exhaustive source laws over finite field contracts" $ do
      let source predicate = "type Flag is a record{  value :: (b :: Bool where " ++ predicate ++ ")} end type\n" ++
            law "Flag" "x = x"
      case check (source "b") >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> do
          let cases = [finiteCases p | u <- plannedUnits plan, p <- plannedProperties u]
          map (fmap length) cases `shouldBe` [Just 1]
      case check (source "false") >>= planTesting of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> map finiteCases (concatMap plannedProperties (plannedUnits plan)) `shouldBe` [Just []]
    it "threads machine width through constructor predicate admission" $ do
      let content = "unit width\ntype Box is a record{  value :: (n :: IntSize where " ++
            "prelude.Int32 n = prelude.Int32 n)} end type\nend unit\n"
          result bits = compileCore bits defaultGeneration [Source "width.lawspec" content]
      result 32 `shouldSatisfy` isRight
      result 64 `shouldSatisfy` isLeft
    it "preserves generic field identities and nested predicates" $ do
      check ("type Box (a :: Type) is a record{  value :: a count :: (n :: Int8 where n > 0)} end type\n" ++
        "function first (box :: Box Int8) -> Int8 is first matching case of box: when Box x count then x end case end function")
        `shouldSatisfy` isRight
      check "type Box is a record{  values :: List (n :: Int8 where n > 0)} end type\n" `shouldSatisfy` isRight
  it "retains named payload predicates in checked Core" $ do
    case check ("type Box (a :: Type) is a record{  value :: a} end type\n" ++
      law "Box (value :: Int8 where value > 0)" "x = x") of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let inputs = concat [propertyInputs property | unit <- programUnits program,
              property <- unitProperties unit]
        map (null . quantifiedPredicates) inputs `shouldBe` [False]
  it "does not capture outer dependencies when lowering sum payload refinements" $ do
    let source value = "law \"|dependent| is definition: for all (lawspecElement :: Int8) " ++
          "(x :: Maybe (value :: Int8 where value > lawspecElement)) => x = x end for all end definition " ++
          "example \"|value| : lawspecElement = 0 x = Present " ++ value ++ " expect x = Present " ++ value ++ " end example end law"
    check (source "1") `shouldSatisfy` isRight
    check (source "0") `shouldSatisfy` isLeft
  forM_ [
      ("recursive products and sums", "type Tree (a :: Type) is one of Leaf  of type a | Branch  of type List (Tree a) end type\n" ++ law "Tree Int8" "x = x"),
      ("forward references", "type A is a record{  value :: B} end type\ntype B is one of B end type\n" ++ law "A" "x = x"),
      ("two type arguments", law "Either (List Int8) (Maybe Bool)" "x = x"),
      ("nested list contexts", law "List (List Int8)" "x = [[], [127]]"),
      ("literal equality from the left", law "List Int8" "[127, -128] = x"),
      ("algebraic nested absence", law "Maybe (Maybe Bool)" "x = Present Absent"),
      ("Either contextual payload", law "Either Int8 Bool" "x = Left 127"),
      ("complementary constructor contexts", law "Bool" "(Left (127 :: Int8)) = (Right true)"),
      ("list length", law "List Int8" "prelude.length x >= 0"),
      ("exhaustive matching", law "Maybe Bool" "(first matching case of x: when Absent then false when Present payload then payload end case) = true"),
      ("nested local matching", law "Maybe (Maybe Bool)" "(first matching case of x: when Absent then false when Present x then first matching case of x: when Absent then false when Present x then x end case end case) = true"),
      ("product matching", "type Pair (a :: Type) is a record{  first :: a second :: Bool} end type\n" ++ law "Pair Int8" "(first matching case of x: when Pair first second then Pair first second end case) = x"),
      -- An undeclared field type variable is a field-only existential.
      ("field-only existentials", "type Box is a record{  value :: a} end type\n")
    ] $ \(label,source) -> it ("accepts " ++ label) $ check source `shouldSatisfy` isRight
  forM_ [
      ("witness fields shadowed by declared fields", "type Box is a record{  value :: a witness :: Bool} end type\n"),
      ("unknown field types", "type Box is a record{  value :: Missing} end type\n"),
      ("unsaturated applications", law "Either Int8" "x = x"),
      ("excess type arguments", law "Maybe Bool Bool" "x = x"),
      ("duplicate declarations", "type Box is one of B end type\ntype Box is one of C end type\n"),
      ("duplicate fields", "type Box is a record{value :: Bool value :: Bool} end type"),
      ("duplicate parameters", "type Box (a :: Type) (a :: Type) is one of B end type\n"),
      ("negative recursion", "type Bad is a record{  value :: (Bad -> Bool)} end type\n"),
      ("range-invalid list elements", law "List Int8" "x = [128]"),
      ("heterogeneous list elements", law "List Int8" "x = [1, true]"),
      ("constructor payload mismatch", law "Maybe Bool" "x = Present 127"),
      ("missing constructor argument", law "Maybe Bool" "x = Present"),
      ("extra constructor argument", law "Maybe Bool" "x = Absent true"),
      ("foreign constructors", law "Maybe Bool" "x = Left true"),
      ("incomplete match", law "Maybe Bool" "(first matching case of x: when Absent then false end case) = true"),
      ("escaping branch binder", law "Maybe Bool" "(first matching case of x: when Absent then p when Present p then p end case) = true"),
      ("inconsistent branch results", law "Maybe Bool" "(first matching case of x: when Absent then 1 when Present p then p end case) = true"),
      ("collection arithmetic", law "List Int8" "x + x = x"),
      ("collection presence operations", law "List Bool" "prelude.isPresent x"),
      ("missing generic Eq evidence", "law \"|generic| (f :: List a -> List a) is definition : for all (x :: List a) => f x = x end for all end definition end law\n")
    ] $ \(label,source) -> it ("rejects " ++ label) $ check source `shouldSatisfy` isLeft
  it "refuses Maybe's old constructor names and names the new ones" $
    forM_ [ (law "Maybe Bool" "x = Just true", "Maybe's Just is now Present")
          , (law "Maybe Bool" "x = Nothing", "Maybe's Nothing is now Absent")
          , (law "Maybe Bool" "(first matching case of x: when Nothing then false when Just p then p end case) = true", "is now")
          , ("law \"|old| is definition: for all (x :: Maybe Bool) => x = x end for all end definition example \"|fixture| : x = Nothing expect x = x end example end law\n", "Maybe's Nothing is now Absent") ]
      $ \(source, hint) -> case check source of
          Left diagnostics -> show diagnostics `shouldSatisfy` isInfixOf hint
          Right _ -> expectationFailure ("accepted an old Maybe constructor: " ++ source)
  it "takes the first of repeated constructor cases" $ do
    let body = "function choose (x :: Maybe Bool) -> Bool is first matching case of x: when Absent then false when Absent then true when Present p then p end case end function"
    case check body >>= prepareDefinitions of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right invoke -> invoke (Id "data_test::choose")
        [DataValue (Constructor "Maybe" [TypeArgument (scalarType "Bool")]) (Id "Maybe::Absent") []]
        `shouldBe` Right (ScalarValue (SBool False))
  it "checks example refinements against concrete lists" $ do
    let source xs = "law \"|nonempty| is definition: for all (x :: List Int8 where prelude.length x > 0) => x = x end for all end definition example \"|fixture| : x = " ++ xs ++ " expect x = " ++ xs ++ " end example end law"
    check (source "[1]") `shouldSatisfy` isRight
    check (source "[]") `shouldSatisfy` isLeft
  it "checks uninhabited data separately from execution feasibility" $ do
    case check ("type Empty is one of end type\n" ++ law "Empty" "x = x") of
      Left ds -> expectationFailure (show ds)
      Right program -> case planTesting program of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> map finiteCases (concatMap plannedProperties (plannedUnits plan)) `shouldBe` [Just []]

  it "emits checked native Haskell products and recursive sums" $ do
    let source = "type Tree (a :: Type) is one of Leaf  of type a | Branch  of type List (Tree a) end type\n" ++
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
    let source = Source "collision" "unit lawSpecData\n\necho :: Bool -> Bool\nend unit\n"
    (compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "haskell")
      `shouldSatisfy` isLeft

  it "emits checked native Kotlin recursive adapters and Kotest generators" $ do
    let source = "type Tree (a :: Type) is one of Leaf  of type a | Branch  of type List (Tree a) end type\n" ++
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
      let source = Source "collision" ("unit " ++ unit ++ "\necho :: Bool -> Bool\nend unit\n")
      (compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "kotlin")
        `shouldSatisfy` isLeft
