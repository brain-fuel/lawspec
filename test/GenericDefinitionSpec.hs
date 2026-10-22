-- | Specialization of generic definitions and their result refinements.
module GenericDefinitionSpec (test_genericDefinitionsSpecializeWithProvedResults) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.List (isPrefixOf, nub)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Frontend (compileCore, elaborate)
import LawSpec.Parser (parseSource)
import LawSpec.Compile (validateDefinitionTotality)
import LawSpec.SpecializeDefinitions (specializeDefinitions)
import qualified LawSpec.Model as S
import LawSpec.Scalar (Scalar(..), isInteger)
import LawSpec.Core.Value (Value(..), listValue)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Types (makeRegistry)
import qualified LawSpec.Core.Eval as E
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Testing (planTesting)

source :: String -> Source
source = Source "generic.lawspec" . (\body -> "unit generic\n" ++ body ++ "\nend unit\n")

compile :: String -> Either [Diagnostic] C.Program
compile body = compileCore 64 defaultGeneration [source body]

definitions :: C.Program -> [C.Definition]
definitions = concatMap C.unitDefinitions . C.programUnits

identity :: String
identity = "function identity (x :: a) -> a is x end function\n"

size :: String
size = "function size (xs :: List a) -> Integer is first matching case of xs : when Nil then 0 when Cons head tail then 1 + size tail end case end function\n"

verify :: String -> (C.Program -> Expectation) -> Expectation
verify body check = case compile body of
  Left ds -> expectationFailure (show ds)
  Right program -> check program

examples :: C.Program -> Expectation
examples program = case (prepareDefinitions program, makeRegistry (C.programDataDeclarations program)) of
  (Right invoke, Right registry) -> forM_ (concatMap C.unitProperties (C.programUnits program)) $ \property ->
    forM_ (C.propertyExamples property) $ \example ->
      case mapM (\(name, expression) -> (,) name <$> E.evaluateValue registry
            (C.programMachineBits program) invoke [] expression) (C.exampleBindings example) of
        Left message -> expectationFailure message
        Right values -> forM_ (C.exampleExpectations example) $ \expectation ->
          E.evaluateValueProposition registry (C.programMachineBits program) invoke values expectation `shouldBe` Right True
  (Left ds, _) -> expectationFailure (show ds)
  (_, Left message) -> expectationFailure message

-- | Exercise the internal specialization boundary independently of public source
-- lowering. Only the fixture's concrete Integer capabilities occur.
specializeRefined :: Int -> String -> Either [Diagnostic] C.Program
specializeRefined bits text = do
  unit <- parseSource (source text)
  validateDefinitionTotality [] bits unit
  let satisfies (S.Capability "Integer" (S.Named name)) = isInteger name
      satisfies _ = False
  (units,properties) <- specializeDefinitions [] bits satisfies [unit] []
  elaborate bits units properties

-- | A caller relies on a callee's proved result to justify division and
-- narrowing, so a guarantee may be used only where it was proved and never
-- across a circular contract. ref:DEC-total-definitions
-- ref:REQ-generic-specialization
test_genericDefinitionsSpecializeWithProvedResults :: Spec
test_genericDefinitionsSpecializeWithProvedResults = describe "generic definition specialization" $ do
  it "proves constructor-sensitive Maybe and Either result refinements" $ do
    verify (unlines
      [ "function wrap (x :: Int8 where x > 0) -> Maybe (value :: Int8 where value > 0) is Present x end function\n"
      , "function empty (x :: Int8) -> Maybe (value :: Int8 where false) is Absent end function\n"
      , "function left (x :: Int8 where x > 0) -> Either (value :: Int8 where value > 0) (value :: Int8 where value < 0) is Left x end function\n"
      , "function right (x :: Int8 where x < 0) -> Either (value :: Int8 where value > 0) (value :: Int8 where value < 0) is Right x end function\n"
      , "function nested (x :: Int8 where x > 0) -> Maybe (Either (value :: Int8 where value > 0) Bool) is Present (Left x) end function\n"
      , "function unwrap (x :: Maybe (value :: Int8 where value != 0)) -> Rational is first matching case of x : when Absent then 0 when Present value then 1 / value end case end function\n" ]) $ \program ->
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "proves named product refinements with dependent fields" $ do
    let declarations = "type Range is a record{  lower :: Int8 upper :: Int8} end type\n"
        definition = "function gap (x :: Range where first matching case of x : when Range lo hi then hi > lo end case) -> Rational is first matching case of x : when Range lo hi then 1 / (hi - lo) end case end function\n"
    verify (declarations ++ definition ++ unlines
      [ "function build (lo :: Int8) (hi :: Int8 where hi > lo) -> (result :: Range where first matching case of result : when Range low high then high > low end case) is Range lo hi end function\n"
      , "function gapbuilt (lo :: Int8) (hi :: Int8 where hi > lo) -> Rational is gap (build lo hi) end function\n"
      , "law \"|gap| is definition : for all (lo :: Int8) (hi :: Int8 where hi > lo) => gap (build lo hi) = 1 / (hi - lo) end for all end definition"
      , "example \"|maximum gap| : lo = -128 hi = 127 expect gapbuilt lo hi = rational(1,255) end example end law" ]) examples
    compile (declarations ++ "function bad (lo :: Int8) (hi :: Int8 where hi > lo) -> (result :: Range where first matching case of result : when Range low high then high > low end case) is Range hi lo end function\n")
      `shouldSatisfy` isLeft
  it "keeps sum payload facts within the selected constructor and value" $ do
    forM_ [ "function bad (x :: Int8) -> Maybe (value :: Int8 where value > 0) is Present x end function\n"
          , "function bad (x :: Int8 where x > 0) -> Either (value :: Int8 where value > 0) (value :: Int8 where value < 0) is Right x end function\n"
          , "function bad (x :: Maybe (value :: Int8 where value != 0)) (y :: Int8) -> Rational is first matching case of x : when Absent then 0 when Present value then 1 / y end case end function\n"
          , "function bad (x :: Either (value :: Int8 where value != 0) Int8) -> Rational is first matching case of x : when Left value then 1 / value when Right value then 1 / value end case end function\n" ] $ \text ->
        case compile text of
          Left diagnostics -> map code diagnostics `shouldContain` ["total"]
          Right _ -> expectationFailure "invalid constructor refinement admitted"
  it "uses verified helper results for exact division, narrowing and subsequent calls" $ do
    let text = unlines
          [ "function positive (x :: Int8) -> (result :: Integer where result > 0) is x + 129 end function\n"
          , "function bounded (x :: Int8 where x >= 0) -> (result :: Integer where result >= 0 && result <= 127) is x + 0 end function\n"
          , "function reciprocal (x :: Int8) -> Rational is 1 / positive x end function\n"
          , "function narrow (x :: Int8 where x >= 0) -> Int8 is prelude.Int8 (bounded x) end function\n"
          , "function consume (x :: Integer where x > 0) -> Rational is 1 / x end function\n"
          , "function nested (x :: Int8) -> Rational is consume (positive x) end function\n" ]
    verify text $ \program -> do
      case prepareDefinitions program of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right run -> do
          run (C.Id "generic::reciprocal") [ScalarValue (SInteger "Int8" (-128))]
            `shouldBe` Right (ScalarValue (SRational 1 1))
          run (C.Id "generic::narrow") [ScalarValue (SInteger "Int8" 127)]
            `shouldBe` Right (ScalarValue (SInteger "Int8" 127))
      forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
    compile "function wrong (x :: Int8) -> (result :: Integer where result > 0 && result <= 128) is x + 129 end function\n"
      `shouldSatisfy` isLeft
  it "proves recursive List result contracts by structural induction" $ do
    verify (unlines
      [ "function copy (xs :: List (value :: Int8 where value > 0)) -> List (value :: Int8 where value > 0) is"
      , "first matching case of xs : when Nil then [] when Cons first rest then Cons first (copy rest) end case end function"
      , "function forward (xs :: List (value :: Int8 where value > 10)) -> List (value :: Int8 where value > 0) is copy xs end function\n" ]) $ \program ->
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            let values = listValue (C.scalarType "Int8") [ScalarValue (SInteger "Int8" 11), ScalarValue (SInteger "Int8" 127)]
            run (C.Id "generic::forward") [values] `shouldBe` Right values
  it "proves scoped helper guarantees inside Boolean and universal result predicates" $ do
    verify (unlines
      [ "function positive (x :: Int8) -> (result :: Integer where result > 0) is x + 129 end function\n"
      , "function keep (x :: Int8) -> (result :: Int8 where result = x && positive result > 0) is x end function\n"
      , "function keepall (xs :: List Int8) -> List (value :: Int8 where positive value > 0) is xs end function\n"
      , "function guarded (x :: Int8) -> (result :: Int8 where result = x || positive result > 0) is x end function\n" ]) $ \program ->
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "rejects circular, premature and invalid callee guarantees" $ do
    forM_ [ "function bad (x :: Int8) -> (result :: Integer where result > 0) is x + 0 end function\n\nfunction use (x :: Int8) -> Rational is 1 / bad x end function\n"
          , "function need (x :: Int8 where x > 0) -> (result :: Int8 where result > 0) is x end function\n\nfunction bad (x :: Int8) -> Rational is 1 / need x end function\n"
          , "function bad (xs :: List Int8) -> (result :: Integer where result > 0) is bad xs end function\n"
          , "function same (xs :: List Int8) -> List Int8 is xs end function\n\nfunction bad (xs :: List Int8) -> Integer is first matching case of xs : when Nil then 0 when Cons first rest then bad (same rest) end case end function\n" ] $ \text ->
        compile text `shouldSatisfy` isLeft
  it "keeps callee guarantees local to short-circuit evaluation" $ do
    let helper = "function need (x :: Int8 where x > 0) -> (result :: Int8 where result > 0) is x end function\n"
    compile (helper ++ "function guarded (x :: Int8) -> Bool is x <= 0 || need x > 0 end function\n")
      `shouldSatisfy` isRight
    compile (helper ++ "function wrong (x :: Int8) -> Bool is x <= 0 && need x > 0 end function\n")
      `shouldSatisfy` isLeft
    compile (helper ++ "function wrong (x :: Int8) -> Bool is (x <= 0 || need x > 0) && 1 / x > 0 end function\n")
      `shouldSatisfy` isLeft
    compile (helper ++ "function wrong (x :: Int8 where x > 0) (y :: Int8) -> Rational is need x / y end function\n")
      `shouldSatisfy` isLeft
  it "executes bundled universal List contract examples at both machine widths" $ do
    text <- readFile "examples/specs/list_contracts.lawspec"
    forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [Source "list_contracts.lawspec" text] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "executes bundled refined-definition examples and emits every target" $ do
    text <- readFile "examples/specs/refined_definitions.lawspec"
    forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [Source "refined_definitions.lawspec" text] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "compiles public refined definitions and aliases through proof, specialization and every emitter" $ do
    let text = unlines
          [ "refinement Nonzero (T :: Type) requires Integer T is (value :: T where value != 0) end refinement"
          , "function reciprocal (x :: Nonzero a) -> Rational requires Integer a is 1 / x end function"
          , "function next (x :: Int8 where x < 127) -> (result :: Int8 where result > x) is prelude.Int8 (x + 1) end function\n"
          , "law \"|reciprocal| is definition : for all (x :: Int8 where x != 0) => reciprocal x = 1 / x end for all end definition"
          , "example \"|half| : x = 2 expect reciprocal x = rational(1, 2) end example end law"
          , "law \"|next| is definition : for all (x :: Int8 where x < 127) => next x = x + 1 end for all end definition end law" ]
    forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [source text] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (concatMap C.unitContracts (C.programUnits program)) `shouldBe` 2
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "rejects invalid public refined definitions even when unused" $ do
    forM_ [ "function bad (x :: a where x >= 0) -> Rational requires Integer a is 1 / x end function\n"
          , "function bad (x :: a) -> (result :: Integer where result < x) requires Integer a is x + 1 end function\n"
          , "function bad (x :: Int8 where later > x) (later :: Int8) -> Int8 is x end function\n"
          , "function positive (x :: Int8 where x > 0) -> Int8 is x end function\n\nfunction bad (x :: Int8) -> Int8 is positive x end function\n" ] $ \text ->
        compile text `shouldSatisfy` isLeft
  it "retains distinct contracts for concrete instances of a refined generic template" $ do
    let text = unlines
          [ "function reciprocal (x :: a where x != 0) -> Rational requires Integer a is 1 / x end function\n"
          , "function small (x :: Int8 where x > 0) -> Rational is reciprocal x end function\n"
          , "function wide (x :: Int64 where x < 0) -> Rational is reciprocal x end function\n" ]
    forM_ [32,64] $ \bits -> case specializeRefined bits text of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (definitions program) `shouldBe` 4
        length (concatMap C.unitContracts (C.programUnits program)) `shouldBe` 4
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            run (C.Id "generic::small") [ScalarValue (SInteger "Int8" 2)]
              `shouldBe` Right (ScalarValue (SRational 1 2))
            run (C.Id "generic::wide") [ScalarValue (SInteger "Int64" (-2))]
              `shouldBe` Right (ScalarValue (SRational (-1) 2))
            run (C.Id "generic::small") [ScalarValue (SInteger "Int8" 0)] `shouldSatisfy` isLeft
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "audits every source List payload predicate before admitting a definition" $ do
    compile "function bad (xs :: List (value :: Int8 where 1 / value > 0)) -> Bool is true end function\n"
      `shouldSatisfy` isLeft
    compile "function good (xs :: List (value :: Int8 where value != 0 && 1 / value > 0)) -> Bool is true end function\n"
      `shouldSatisfy` isRight
    compile "function missing (xs :: List (value :: a where value > 0)) -> Bool is true end function\n"
      `shouldSatisfy` isLeft
  it "uses List membership facts for heads, tails and structural recursion" $ do
    let sourceText = unlines
          [ "function total (xs :: List (value :: Int8 where value != 0)) -> Rational is"
          , "first matching case of xs : when Nil then 0 when Cons first rest then 1 / first + total rest end case end function"
          , "function tail (xs :: List (value :: Int8 where value > 0)) -> List (value :: Int8 where value > 0) is"
          , "first matching case of xs : when Nil then [] when Cons first rest then rest end case end function"
          , "function first (xs :: List (value :: Int8 where value > 0)) -> (result :: Int8 where result > 0) is"
          , "first matching case of xs : when Nil then 1 when Cons first rest then first end case end function" ]
    case compile sourceText of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            let values xs = listValue (C.scalarType "Int8") (map (ScalarValue . SInteger "Int8") xs)
            run (C.Id "generic::total") [values [1,2]] `shouldBe` Right (ScalarValue (SRational 3 2))
            run (C.Id "generic::total") [values []] `shouldBe` Right (ScalarValue (SRational 0 1))
            run (C.Id "generic::total") [values [0]] `shouldSatisfy` isLeft
            run (C.Id "generic::tail") [values [1,2]] `shouldBe` Right (values [2])
            run (C.Id "generic::first") [values []] `shouldBe` Right (ScalarValue (SInteger "Int8" 1))
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "keeps List membership facts scoped to the matching branch and list" $ do
    forM_ [ "function bad (xs :: List (value :: Int8 where value != 0)) -> Rational is first matching case of xs : when Nil then 1 / 0 when Cons first rest then 1 / first end case end function\n"
          , "function bad (xs :: List Int8) -> Rational is first matching case of xs : when Nil then 0 when Cons first rest then 1 / first end case end function\n"
          , "function bad (xs :: List (value :: Int8 where value != 0)) (ys :: List Int8) -> Rational is first matching case of ys : when Nil then 0 when Cons first rest then 1 / first end case end function\n"
          , "function bad (xs :: List (value :: Int8 where value != 0)) (other :: Int8) -> Rational is first matching case of xs : when Nil then 0 when Cons first rest then 1 / other end case end function\n"
          , "function bad (xs :: List (value :: Int8 where value != 0)) -> Rational is first matching case of xs : when Nil then 0 when Cons first rest then bad xs end case end function\n" ] $ \text -> case compile text of
        Left diagnostics -> map code diagnostics `shouldContain` ["total"]
        Right _ -> expectationFailure "invalid List branch admitted"
  it "knows exactly which List is empty in a Nil branch" $ do
    compile "function emptycase (xs :: List Int8) -> List (value :: Int8 where false) is first matching case of xs : when Nil then xs when Cons first rest then [] end case end function\n"
      `shouldSatisfy` isRight
    compile "function bad (xs :: List Int8) -> List (value :: Int8 where false) is first matching case of xs : when Nil then [] when Cons first rest then xs end case end function\n"
      `shouldSatisfy` isLeft
    compile "function bad (xs :: List Int8) (ys :: List Int8) -> List (value :: Int8 where false) is first matching case of xs : when Nil then ys when Cons first rest then [] end case end function\n"
      `shouldSatisfy` isLeft
  it "retains prior scalar dependencies in a tail contract" $ do
    compile (unlines
      [ "function count (floor :: Int8) (xs :: List (value :: Int8 where value > floor)) -> Integer is"
      , "first matching case of xs : when Nil then 0 when Cons first rest then 1 + count floor rest end case end function" ])
      `shouldSatisfy` isRight
    compile (unlines
      [ "function count (floor :: Int8) (xs :: List (value :: Int8 where value > floor)) -> Integer is"
      , "first matching case of xs : when Nil then 0 when Cons first rest then 1 + count 127 rest end case end function" ])
      `shouldSatisfy` isLeft
  it "transfers universal List contracts through generic helper calls" $ do
    let text = unlines
          [ "function positive (x :: a) -> Bool requires Integer a is x > 0 end function\n"
          , "function keep (xs :: List (value :: a where positive value)) -> List a requires Integer a is xs end function\n"
          , "function small (xs :: List (value :: Int8 where positive value)) -> List Int8 is keep xs end function\n" ]
    case compile text of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            let values xs = listValue (C.scalarType "Int8") (map (ScalarValue . SInteger "Int8") xs)
            run (C.Id "generic::small") [values []] `shouldBe` Right (values [])
            run (C.Id "generic::small") [values [1,2]] `shouldBe` Right (values [1,2])
            run (C.Id "generic::small") [values [0]] `shouldSatisfy` isLeft
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "proves stronger numeric and nested List contracts without exchanging list identities" $ do
    let callee = "function keep (xs :: List (value :: Int8 where value > 0)) -> List Int8 is xs end function\n"
    compile (callee ++ "function caller (xs :: List (value :: Int8 where value > 10)) -> List Int8 is keep xs end function\n")
      `shouldSatisfy` isRight
    compile (callee ++ "function caller (xs :: List (value :: Int8 where value >= 0)) -> List Int8 is keep xs end function\n")
      `shouldSatisfy` isLeft
    compile (callee ++ "function caller (xs :: List (value :: Int8 where value > 0)) (ys :: List Int8) -> List Int8 is keep ys end function\n")
      `shouldSatisfy` isLeft
    compile (unlines
      [ "function keep (xs :: List (List (value :: Int8 where value > 0))) -> List (List Int8) is xs end function\n"
      , "function caller (xs :: List (List (value :: Int8 where value > 1))) -> List (List Int8) is keep xs end function\n" ])
      `shouldSatisfy` isRight
  it "proves universal postconditions on returned and constructed Lists" $ do
    compile "function keep (xs :: List (value :: Int8 where value > 1)) -> List (result :: Int8 where result > 0) is xs end function\n"
      `shouldSatisfy` isRight
    compile "function empty (ignored :: Unit) -> List (value :: Int8 where false) is [] end function\n"
      `shouldSatisfy` isRight
    compile "function positive (ignored :: Unit) -> List (value :: Int8 where value > 0) is [1, 2] end function\n"
      `shouldSatisfy` isRight
    compile "function invalid (ignored :: Unit) -> List (value :: Int8 where value > 0) is [1, 0] end function\n"
      `shouldSatisfy` isLeft
    compile (unlines
      [ "function keep (xs :: List (value :: Int8 where value > 0)) -> List Int8 is xs end function\n"
      , "function empty (ignored :: Unit) -> List Int8 is keep [] end function\n" ])
      `shouldSatisfy` isRight
  it "does not equate Boolean calls whose argument computations were erased from the proof view" $ do
    case compile (unlines
      [ "function identity (value :: Bool) -> Bool is value end function\n"
      , "function bad (value :: Float64 where identity (prelude.isNaN value)) -> (result :: Bool where result) is identity (prelude.isFinite value) end function\n" ]) of
      Left diagnostics -> map code diagnostics `shouldContain` ["total"]
      Right _ -> expectationFailure "erased computations established a false postcondition"
  it "does not infer an outer scalar fact from a possibly empty refined List" $ do
    compile "function bad (xs :: List (value :: Int8 where value > 0)) (value :: Int8) -> Rational is 1 / value end function\n"
      `shouldSatisfy` isLeft
    compile "function bad (xs :: List (value :: Int8 where false)) (value :: Int8) -> Rational is 1 / value end function\n"
      `shouldSatisfy` isLeft
  it "specializes generic helpers under List payload contracts" $ do
    let text = unlines
          [ "function positive (x :: a) -> Bool requires Integer a is x > 0 end function\n"
          , "function keep (xs :: List (value :: a where positive value)) -> List a requires Integer a is xs end function\n"
          , "law \"|specialize| is definition : for all (xs :: List (value :: Int8 where value > 0)) => keep xs = xs end for all end definition end law" ]
    case compile text of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            let values xs = listValue (C.scalarType "Int8") (map (ScalarValue . SInteger "Int8") xs)
                names = [C.declarationId declaration | d <- definitions program,
                  let declaration = C.definitionDeclaration d,
                  C.declarationType declaration == C.Arrow
                    (C.Constructor "List" [C.TypeArgument (C.scalarType "Int8")])
                    (C.Constructor "List" [C.TypeArgument (C.scalarType "Int8")])]
            length names `shouldBe` 1
            let name = head names
            run name [values []] `shouldBe` Right (values [])
            run name [values [1,2]] `shouldBe` Right (values [1,2])
            run name [values [1,0]] `shouldSatisfy` isLeft
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "discovers generic helper instances used only in a definition precondition" $ do
    let text = unlines
          [ "function positive (x :: a) -> Bool requires Integer a is x > 0 end function\n"
          , "function keep (x :: Int8 where positive x) -> Int8 is x end function\n" ]
    case specializeRefined 64 text of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (definitions program) `shouldBe` 2
        length (concatMap C.unitContracts (C.programUnits program)) `shouldBe` 1
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            run (C.Id "generic::keep") [ScalarValue (SInteger "Int8" 1)]
              `shouldBe` Right (ScalarValue (SInteger "Int8" 1))
            run (C.Id "generic::keep") [ScalarValue (SInteger "Int8" 0)] `shouldSatisfy` isLeft
  it "preserves contracts for concrete-only units and erases refinements only from value signatures" $ do
    case specializeRefined 64 "function next (x :: Int8 where x < 127) -> (result :: Int8 where result > x) is prelude.Int8 (x + 1) end function\n" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (concatMap C.unitContracts (C.programUnits program)) `shouldBe` 1
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> run (C.Id "generic::next") [ScalarValue (SInteger "Int8" 126)]
            `shouldBe` Right (ScalarValue (SInteger "Int8" 127))
  it "creates independent concrete instances in one assertion and emits all targets" $
    verify (identity ++ "law \"|both| is definition: for all (x :: Bool) (y :: Text) => identity x = x and identity y = y end " ++
      "for all end definition example \"|values| : x = true y = \"raw\" expect identity x = true expect identity y = \"raw\" end example end law") $ \program -> do
        length (definitions program) `shouldBe` 2
        map (C.declarationType . C.definitionDeclaration) (definitions program) `shouldMatchList`
          [C.Arrow (C.scalarType "Bool") (C.scalarType "Bool"), C.Arrow (C.scalarType "Text") (C.scalarType "Text")]
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "reuses a recursive instance and discovers transitive calls" $
    verify ("function forward (xs :: List a) -> Integer is size xs end function\n" ++ size ++
      "law \"|length| is definition: for all (xs :: List Int8) => forward xs = size xs end " ++
      "for all end definition example \"|three| : xs = [1, 2, 3] expect forward xs = 3 end example end law") $ \program -> do
        length (definitions program) `shouldBe` 2
        examples program
  it "specializes calls from unused concrete definitions" $
    verify (identity ++ "function boolean (x :: Bool) -> Bool is identity x end function\n") $ \program ->
      length (definitions program) `shouldBe` 2
  it "includes instances used only by concrete examples" $
    verify (size ++ "law \"|example| is definition: for all (x :: Int8) => x = x end " ++
      "for all end definition example \"|call| : x = 127 expect size [x, x] = 2 end example end law") $ \program -> do
        length (definitions program) `shouldBe` 1
        examples program
  it "specializes constrained integer arithmetic without wrapping" $
    verify ("function next (x :: a) -> Integer requires Integer a is x + 1 end function\n" ++
      "law \"|promotion| is definition: for all (x :: Int8) => next x = x + 1 end for all end definition " ++
      "example \"|maximum| : x = 127 expect next x = 128 end example end law") examples
  it "checks capabilities at each call and rejects unused unsafe templates" $ do
    compile ("function next (x :: a) -> Integer requires Integer a is x + 1 end function\n" ++
      "law \"|bad| is definition : for all (x :: Float64) => next x = 0 end for all end definition end law\n") `shouldSatisfy` isLeft
    compile ("function divide (x :: a) -> Rational requires Integer a is 1 / x end function\n" ++
      "law \"|unrelated| is definition : true end definition end law\n") `shouldSatisfy` isLeft
  it "resolves empty containers from an explicit result context" $
    verify (identity ++ "law \"|empty| is definition : (identity [] :: List Int8) = [] end definition end law\n") $ \program ->
      length (definitions program) `shouldBe` 1
  it "specializes an annotated generic function supplied to a reusable law" $
    verify (identity ++ "law \"|twice| is definition : apply law \"|involution| (identity :: List Int8 -> List Int8) end definition end law\n") $ \program -> do
      length (definitions program) `shouldBe` 1
      forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "specializes result-only type parameters from context" $
    verify ("function empty (x :: Unit) -> List a is [] end function\n" ++
      "law \"|empty| is definition : for all (x :: Unit) => (empty x :: List Int8) = [] end for all end definition end law\n") $ \program ->
      length (definitions program) `shouldBe` 1
  it "specializes recursive named data and nested absence payloads" $
    verify ("type Tree (a :: Type) is one of Leaf  of type a | Branch of type record{ left :: Tree a right :: Tree a} end type\n" ++
      "function leaves (tree :: Tree a) -> Integer is first matching case of tree: when Leaf value then 1 when Branch record{left = left, right = right} then leaves left + leaves right end case end function\n" ++
      identity ++ "law \"|tree| is definition: for all (x :: Tree (Optional (Nullable Int8))) => identity x = x end for all end definition " ++
      "example \"|count| : x = Leaf undefined expect leaves x = 1 end example end law") $ \program -> do
        length (definitions program) `shouldBe` 2
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "rejects genuinely ambiguous specializations and cross-type recursive growth" $ do
    compile ("function empty (x :: Unit) -> List a is [] end function\n" ++
      "law \"|ambiguous| is definition : for all (x :: Unit) => prelude.length (empty x) = 0 end for all end definition end law\n") `shouldSatisfy` isLeft
    compile "function grow (xs :: List a) -> Integer is grow [xs] end function\n" `shouldSatisfy` isLeft
  it "keeps local values separate from generic declarations of the same name" $
    verify (identity ++ "function local (identity :: Bool) -> Bool is identity end function\n" ++
      "law \"|local| is definition : for all (x :: Bool) => local x = x end for all end definition end law\n") $ \program ->
      map (C.declarationName . C.definitionDeclaration) (definitions program) `shouldBe` ["local"]
  it "keeps instance names stable and avoids existing declaration names" $ do
    let body = identity ++ "law \"|identity| is definition : for all (x :: Bool) => identity x = x end for all end definition end law\n"
    verify body $ \program -> do
      let names = map (C.declarationName . C.definitionDeclaration) (definitions program)
      length names `shouldBe` 1
      names `shouldSatisfy` all (isPrefixOf "lawspec_identity_")
      verify (body ++ "\nlaw \"|unrelated| is definition : true end definition end law\n") $ \other ->
        map (C.declarationName . C.definitionDeclaration) (definitions other) `shouldBe` names
      verify (head names ++ " :: Bool -> Bool\n" ++ body) $ \other -> do
        let declared = concatMap C.unitDeclarations (C.programUnits other)
            identifiers = map C.declarationName declared
        length identifiers `shouldBe` length (nub identifiers)
        map (C.declarationName . C.definitionDeclaration) (definitions other) `shouldNotBe` names
