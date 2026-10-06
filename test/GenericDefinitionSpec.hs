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
source = Source "generic.lawspec" . ("unit generic\n" ++)

compile :: String -> Either [Diagnostic] C.Program
compile body = compileCore 64 defaultGeneration [source body]

definitions :: C.Program -> [C.Definition]
definitions = concatMap C.unitDefinitions . C.programUnits

identity :: String
identity = "definition identity (x :: a) :: a is x end\n"

size :: String
size = "definition size (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + size tail end end\n"

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
      ["definition wrap (x :: Int8 where x > 0) :: Maybe (value :: Int8 where value > 0) is Just x end",
       "definition empty (x :: Int8) :: Maybe (value :: Int8 where false) is Nothing end",
       "definition left (x :: Int8 where x > 0) :: Either (value :: Int8 where value > 0) (value :: Int8 where value < 0) is Left x end",
       "definition right (x :: Int8 where x < 0) :: Either (value :: Int8 where value > 0) (value :: Int8 where value < 0) is Right x end",
       "definition nested (x :: Int8 where x > 0) :: Maybe (Either (value :: Int8 where value > 0) Bool) is Just (Left x) end",
       "definition unwrap (x :: Maybe (value :: Int8 where value != 0)) :: Rational is match x with | Nothing -> 0 | Just value -> 1 / value end end"]) $ \program ->
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "proves named product refinements with dependent fields" $ do
    let declarations = "type Range is Range lower :: Int8 upper :: Int8 end\n"
        definition = "definition gap (x :: Range where match x with | Range lo hi -> hi > lo end) :: Rational is match x with | Range lo hi -> 1 / (hi - lo) end end\n"
    verify (declarations ++ definition ++ unlines
      ["definition build (lo :: Int8) (hi :: Int8 where hi > lo) :: (result :: Range where match result with | Range low high -> high > low end) is Range lo hi end",
       "definition gapbuilt (lo :: Int8) (hi :: Int8 where hi > lo) :: Rational is gap (build lo hi) end",
       "law `gap` is definition is `for all` (lo :: Int8) (hi :: Int8 where hi > lo) . gap (build lo hi) = 1 / (hi - lo) end",
       "example `maximum gap` is lo = -128 hi = 127 expect gapbuilt lo hi = rational(1,255) end end"]) examples
    compile (declarations ++ "definition bad (lo :: Int8) (hi :: Int8 where hi > lo) :: (result :: Range where match result with | Range low high -> high > low end) is Range hi lo end")
      `shouldSatisfy` isLeft
  it "keeps sum payload facts within the selected constructor and value" $ do
    forM_ [
      "definition bad (x :: Int8) :: Maybe (value :: Int8 where value > 0) is Just x end",
      "definition bad (x :: Int8 where x > 0) :: Either (value :: Int8 where value > 0) (value :: Int8 where value < 0) is Right x end",
      "definition bad (x :: Maybe (value :: Int8 where value != 0)) (y :: Int8) :: Rational is match x with | Nothing -> 0 | Just value -> 1 / y end end",
      "definition bad (x :: Either (value :: Int8 where value != 0) Int8) :: Rational is match x with | Left value -> 1 / value | Right value -> 1 / value end end"] $ \text ->
        case compile text of
          Left diagnostics -> map code diagnostics `shouldContain` ["total"]
          Right _ -> expectationFailure "invalid constructor refinement admitted"
  it "uses verified helper results for exact division, narrowing and subsequent calls" $ do
    let text = unlines
          ["definition positive (x :: Int8) :: (result :: BigInt where result > 0) is x + 129 end",
           "definition bounded (x :: Int8 where x >= 0) :: (result :: BigInt where result >= 0 && result <= 127) is x + 0 end",
           "definition reciprocal (x :: Int8) :: Rational is 1 / positive x end",
           "definition narrow (x :: Int8 where x >= 0) :: Int8 is prelude.Int8 (bounded x) end",
           "definition consume (x :: BigInt where x > 0) :: Rational is 1 / x end",
           "definition nested (x :: Int8) :: Rational is consume (positive x) end"]
    verify text $ \program -> do
      case prepareDefinitions program of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right run -> do
          run (C.Id "generic::reciprocal") [ScalarValue (SInteger "Int8" (-128))]
            `shouldBe` Right (ScalarValue (SRational 1 1))
          run (C.Id "generic::narrow") [ScalarValue (SInteger "Int8" 127)]
            `shouldBe` Right (ScalarValue (SInteger "Int8" 127))
      forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
    compile "definition wrong (x :: Int8) :: (result :: BigInt where result > 0 && result <= 128) is x + 129 end"
      `shouldSatisfy` isLeft
  it "proves recursive List result contracts by structural induction" $ do
    verify (unlines
      ["definition copy (xs :: List (value :: Int8 where value > 0)) :: List (value :: Int8 where value > 0) is",
       "match xs with | Nil -> [] | Cons first rest -> Cons first (copy rest) end end",
       "definition forward (xs :: List (value :: Int8 where value > 10)) :: List (value :: Int8 where value > 0) is copy xs end"]) $ \program ->
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> do
            let values = listValue (C.scalarType "Int8") [ScalarValue (SInteger "Int8" 11), ScalarValue (SInteger "Int8" 127)]
            run (C.Id "generic::forward") [values] `shouldBe` Right values
  it "proves scoped helper guarantees inside Boolean and universal result predicates" $ do
    verify (unlines
      ["definition positive (x :: Int8) :: (result :: BigInt where result > 0) is x + 129 end",
       "definition keep (x :: Int8) :: (result :: Int8 where result == x && positive result > 0) is x end",
       "definition keepall (xs :: List Int8) :: List (value :: Int8 where positive value > 0) is xs end",
       "definition guarded (x :: Int8) :: (result :: Int8 where result == x || positive result > 0) is x end"]) $ \program ->
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "rejects circular, premature and invalid callee guarantees" $ do
    forM_ [
      "definition bad (x :: Int8) :: (result :: BigInt where result > 0) is x + 0 end\ndefinition use (x :: Int8) :: Rational is 1 / bad x end",
      "definition need (x :: Int8 where x > 0) :: (result :: Int8 where result > 0) is x end\ndefinition bad (x :: Int8) :: Rational is 1 / need x end",
      "definition bad (xs :: List Int8) :: (result :: BigInt where result > 0) is bad xs end",
      "definition same (xs :: List Int8) :: List Int8 is xs end\ndefinition bad (xs :: List Int8) :: BigInt is match xs with | Nil -> 0 | Cons first rest -> bad (same rest) end end"] $ \text ->
        compile text `shouldSatisfy` isLeft
  it "keeps callee guarantees local to short-circuit evaluation" $ do
    let helper = "definition need (x :: Int8 where x > 0) :: (result :: Int8 where result > 0) is x end\n"
    compile (helper ++ "definition guarded (x :: Int8) :: Bool is x <= 0 || need x > 0 end")
      `shouldSatisfy` isRight
    compile (helper ++ "definition wrong (x :: Int8) :: Bool is x <= 0 && need x > 0 end")
      `shouldSatisfy` isLeft
    compile (helper ++ "definition wrong (x :: Int8) :: Bool is (x <= 0 || need x > 0) && 1 / x > 0 end")
      `shouldSatisfy` isLeft
    compile (helper ++ "definition wrong (x :: Int8 where x > 0) (y :: Int8) :: Rational is need x / y end")
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
          ["refinement Nonzero (T :: Type) requires Integer T is (value :: T where value != 0) end",
           "definition reciprocal (x :: Nonzero a) :: Rational requires Integer a is 1 / x end",
           "definition next (x :: Int8 where x < 127) :: (result :: Int8 where result > x) is prelude.Int8 (x + 1) end",
           "law `reciprocal` is definition is `for all` (x :: Int8 where x != 0) . reciprocal x = 1 / x end",
           "example `half` is x = 2 expect reciprocal x = rational(1, 2) end end",
           "law `next` is definition is `for all` (x :: Int8 where x < 127) . next x = x + 1 end end"]
    forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [source text] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (concatMap C.unitContracts (C.programUnits program)) `shouldBe` 2
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "rejects invalid public refined definitions even when unused" $ do
    forM_ [
      "definition bad (x :: a where x >= 0) :: Rational requires Integer a is 1 / x end",
      "definition bad (x :: a) :: (result :: BigInt where result < x) requires Integer a is x + 1 end",
      "definition bad (x :: Int8 where later > x) (later :: Int8) :: Int8 is x end",
      "definition positive (x :: Int8 where x > 0) :: Int8 is x end\ndefinition bad (x :: Int8) :: Int8 is positive x end"] $ \text ->
        compile text `shouldSatisfy` isLeft
  it "retains distinct contracts for concrete instances of a refined generic template" $ do
    let text = unlines
          ["definition reciprocal (x :: a where x != 0) :: Rational requires Integer a is 1 / x end",
           "definition small (x :: Int8 where x > 0) :: Rational is reciprocal x end",
           "definition wide (x :: Int64 where x < 0) :: Rational is reciprocal x end"]
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
    compile "definition bad (xs :: List (value :: Int8 where 1 / value > 0)) :: Bool is true end"
      `shouldSatisfy` isLeft
    compile "definition good (xs :: List (value :: Int8 where value != 0 && 1 / value > 0)) :: Bool is true end"
      `shouldSatisfy` isRight
    compile "definition missing (xs :: List (value :: a where value > 0)) :: Bool is true end"
      `shouldSatisfy` isLeft
  it "uses List membership facts for heads, tails and structural recursion" $ do
    let sourceText = unlines
          ["definition total (xs :: List (value :: Int8 where value != 0)) :: Rational is",
           "match xs with | Nil -> 0 | Cons first rest -> 1 / first + total rest end end",
           "definition tail (xs :: List (value :: Int8 where value > 0)) :: List (value :: Int8 where value > 0) is",
           "match xs with | Nil -> [] | Cons first rest -> rest end end",
           "definition first (xs :: List (value :: Int8 where value > 0)) :: (result :: Int8 where result > 0) is",
           "match xs with | Nil -> 1 | Cons first rest -> first end end"]
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
    forM_ [
      "definition bad (xs :: List (value :: Int8 where value != 0)) :: Rational is match xs with | Nil -> 1 / 0 | Cons first rest -> 1 / first end end",
      "definition bad (xs :: List Int8) :: Rational is match xs with | Nil -> 0 | Cons first rest -> 1 / first end end",
      "definition bad (xs :: List (value :: Int8 where value != 0)) (ys :: List Int8) :: Rational is match ys with | Nil -> 0 | Cons first rest -> 1 / first end end",
      "definition bad (xs :: List (value :: Int8 where value != 0)) (other :: Int8) :: Rational is match xs with | Nil -> 0 | Cons first rest -> 1 / other end end",
      "definition bad (xs :: List (value :: Int8 where value != 0)) :: Rational is match xs with | Nil -> 0 | Cons first rest -> bad xs end end"
      ] $ \text -> case compile text of
        Left diagnostics -> map code diagnostics `shouldContain` ["total"]
        Right _ -> expectationFailure "invalid List branch admitted"
  it "knows exactly which List is empty in a Nil branch" $ do
    compile "definition emptycase (xs :: List Int8) :: List (value :: Int8 where false) is match xs with | Nil -> xs | Cons first rest -> [] end end"
      `shouldSatisfy` isRight
    compile "definition bad (xs :: List Int8) :: List (value :: Int8 where false) is match xs with | Nil -> [] | Cons first rest -> xs end end"
      `shouldSatisfy` isLeft
    compile "definition bad (xs :: List Int8) (ys :: List Int8) :: List (value :: Int8 where false) is match xs with | Nil -> ys | Cons first rest -> [] end end"
      `shouldSatisfy` isLeft
  it "retains prior scalar dependencies in a tail contract" $ do
    compile (unlines
      ["definition count (floor :: Int8) (xs :: List (value :: Int8 where value > floor)) :: Integer is",
       "match xs with | Nil -> 0 | Cons first rest -> 1 + count floor rest end end"])
      `shouldSatisfy` isRight
    compile (unlines
      ["definition count (floor :: Int8) (xs :: List (value :: Int8 where value > floor)) :: Integer is",
       "match xs with | Nil -> 0 | Cons first rest -> 1 + count 127 rest end end"])
      `shouldSatisfy` isLeft
  it "transfers universal List contracts through generic helper calls" $ do
    let text = unlines
          ["definition positive (x :: a) :: Bool requires Integer a is x > 0 end",
           "definition keep (xs :: List (value :: a where positive value)) :: List a requires Integer a is xs end",
           "definition small (xs :: List (value :: Int8 where positive value)) :: List Int8 is keep xs end"]
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
    let callee = "definition keep (xs :: List (value :: Int8 where value > 0)) :: List Int8 is xs end\n"
    compile (callee ++ "definition caller (xs :: List (value :: Int8 where value > 10)) :: List Int8 is keep xs end")
      `shouldSatisfy` isRight
    compile (callee ++ "definition caller (xs :: List (value :: Int8 where value >= 0)) :: List Int8 is keep xs end")
      `shouldSatisfy` isLeft
    compile (callee ++ "definition caller (xs :: List (value :: Int8 where value > 0)) (ys :: List Int8) :: List Int8 is keep ys end")
      `shouldSatisfy` isLeft
    compile (unlines
      ["definition keep (xs :: List (List (value :: Int8 where value > 0))) :: List (List Int8) is xs end",
       "definition caller (xs :: List (List (value :: Int8 where value > 1))) :: List (List Int8) is keep xs end"])
      `shouldSatisfy` isRight
  it "proves universal postconditions on returned and constructed Lists" $ do
    compile "definition keep (xs :: List (value :: Int8 where value > 1)) :: List (result :: Int8 where result > 0) is xs end"
      `shouldSatisfy` isRight
    compile "definition empty (ignored :: Unit) :: List (value :: Int8 where false) is [] end"
      `shouldSatisfy` isRight
    compile "definition positive (ignored :: Unit) :: List (value :: Int8 where value > 0) is [1, 2] end"
      `shouldSatisfy` isRight
    compile "definition invalid (ignored :: Unit) :: List (value :: Int8 where value > 0) is [1, 0] end"
      `shouldSatisfy` isLeft
    compile (unlines
      ["definition keep (xs :: List (value :: Int8 where value > 0)) :: List Int8 is xs end",
       "definition empty (ignored :: Unit) :: List Int8 is keep [] end"])
      `shouldSatisfy` isRight
  it "does not equate Boolean calls whose argument computations were erased from the proof view" $ do
    case compile (unlines
      ["definition identity (value :: Bool) :: Bool is value end",
       "definition bad (value :: Float64 where identity (prelude.isNaN value)) :: (result :: Bool where result) is identity (prelude.isFinite value) end"]) of
      Left diagnostics -> map code diagnostics `shouldContain` ["total"]
      Right _ -> expectationFailure "erased computations established a false postcondition"
  it "does not infer an outer scalar fact from a possibly empty refined List" $ do
    compile "definition bad (xs :: List (value :: Int8 where value > 0)) (value :: Int8) :: Rational is 1 / value end"
      `shouldSatisfy` isLeft
    compile "definition bad (xs :: List (value :: Int8 where false)) (value :: Int8) :: Rational is 1 / value end"
      `shouldSatisfy` isLeft
  it "specializes generic helpers under List payload contracts" $ do
    let text = unlines
          ["definition positive (x :: a) :: Bool requires Integer a is x > 0 end",
           "definition keep (xs :: List (value :: a where positive value)) :: List a requires Integer a is xs end",
           "law `specialize` is definition is `for all` (xs :: List (value :: Int8 where value > 0)) . keep xs = xs end end"]
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
          ["definition positive (x :: a) :: Bool requires Integer a is x > 0 end",
           "definition keep (x :: Int8 where positive x) :: Int8 is x end"]
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
    case specializeRefined 64 "definition next (x :: Int8 where x < 127) :: (result :: Int8 where result > x) is prelude.Int8 (x + 1) end" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (concatMap C.unitContracts (C.programUnits program)) `shouldBe` 1
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right run -> run (C.Id "generic::next") [ScalarValue (SInteger "Int8" 126)]
            `shouldBe` Right (ScalarValue (SInteger "Int8" 127))
  it "creates independent concrete instances in one assertion and emits all targets" $
    verify (identity ++ "law `both` is definition is `for all` (x :: Bool) (y :: Text) . identity x = x and identity y = y end " ++
      "example `values` is x = true y = \"raw\" expect identity x = true expect identity y = \"raw\" end end") $ \program -> do
        length (definitions program) `shouldBe` 2
        map (C.declarationType . C.definitionDeclaration) (definitions program) `shouldMatchList`
          [C.Arrow (C.scalarType "Bool") (C.scalarType "Bool"), C.Arrow (C.scalarType "Text") (C.scalarType "Text")]
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "reuses a recursive instance and discovers transitive calls" $
    verify ("definition forward (xs :: List a) :: BigInt is size xs end\n" ++ size ++
      "law `length` is definition is `for all` (xs :: List Int8) . forward xs = size xs end " ++
      "example `three` is xs = [1, 2, 3] expect forward xs = 3 end end") $ \program -> do
        length (definitions program) `shouldBe` 2
        examples program
  it "specializes calls from unused concrete definitions" $
    verify (identity ++ "definition boolean (x :: Bool) :: Bool is identity x end") $ \program ->
      length (definitions program) `shouldBe` 2
  it "includes instances used only by concrete examples" $
    verify (size ++ "law `example` is definition is `for all` (x :: Int8) . x = x end " ++
      "example `call` is x = 127 expect size [x, x] = 2 end end") $ \program -> do
        length (definitions program) `shouldBe` 1
        examples program
  it "specializes constrained integer arithmetic without wrapping" $
    verify ("definition next (x :: a) :: BigInt requires Integer a is x + 1 end\n" ++
      "law `promotion` is definition is `for all` (x :: Int8) . next x = x + 1 end " ++
      "example `maximum` is x = 127 expect next x = 128 end end") examples
  it "checks capabilities at each call and rejects unused unsafe templates" $ do
    compile ("definition next (x :: a) :: BigInt requires Integer a is x + 1 end\n" ++
      "law `bad` is definition is `for all` (x :: Float64) . next x = 0 end end") `shouldSatisfy` isLeft
    compile ("definition divide (x :: a) :: Rational requires Integer a is 1 / x end\n" ++
      "law `unrelated` is definition is true end end") `shouldSatisfy` isLeft
  it "resolves empty containers from an explicit result context" $
    verify (identity ++ "law `empty` is definition is (identity [] :: List Int8) = [] end end") $ \program ->
      length (definitions program) `shouldBe` 1
  it "specializes an annotated generic function supplied to a reusable law" $
    verify (identity ++ "law `twice` is definition is `involution` (identity :: List Int8 -> List Int8) end end") $ \program -> do
      length (definitions program) `shouldBe` 1
      forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "specializes result-only type parameters from context" $
    verify ("definition empty (x :: Unit) :: List a is [] end\n" ++
      "law `empty` is definition is `for all` (x :: Unit) . (empty x :: List Int8) = [] end end") $ \program ->
      length (definitions program) `shouldBe` 1
  it "specializes recursive named data and nested absence payloads" $
    verify ("type Tree (a :: Type) is Leaf value :: a | Branch left :: Tree a right :: Tree a end\n" ++
      "definition leaves (tree :: Tree a) :: BigInt is match tree with | Leaf value -> 1 | Branch left right -> leaves left + leaves right end end\n" ++
      identity ++ "law `tree` is definition is `for all` (x :: Tree (Optional (Nullable Int8))) . identity x = x end " ++
      "example `count` is x = Leaf undefined expect leaves x = 1 end end") $ \program -> do
        length (definitions program) `shouldBe` 2
        examples program
        forM_ targets $ \target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight
  it "rejects genuinely ambiguous specializations and cross-type recursive growth" $ do
    compile ("definition empty (x :: Unit) :: List a is [] end\n" ++
      "law `ambiguous` is definition is `for all` (x :: Unit) . prelude.length (empty x) = 0 end end") `shouldSatisfy` isLeft
    compile "definition grow (xs :: List a) :: BigInt is grow [xs] end" `shouldSatisfy` isLeft
  it "keeps local values separate from generic declarations of the same name" $
    verify (identity ++ "definition local (identity :: Bool) :: Bool is identity end\n" ++
      "law `local` is definition is `for all` (x :: Bool) . local x = x end end") $ \program ->
      map (C.declarationName . C.definitionDeclaration) (definitions program) `shouldBe` ["local"]
  it "keeps instance names stable and avoids existing declaration names" $ do
    let body = identity ++ "law `identity` is definition is `for all` (x :: Bool) . identity x = x end end"
    verify body $ \program -> do
      let names = map (C.declarationName . C.definitionDeclaration) (definitions program)
      length names `shouldBe` 1
      names `shouldSatisfy` all (isPrefixOf "lawspec_identity_")
      verify (body ++ "\nlaw `unrelated` is definition is true end end") $ \other ->
        map (C.declarationName . C.definitionDeclaration) (definitions other) `shouldBe` names
      verify (head names ++ " :: Bool -> Bool\n" ++ body) $ \other -> do
        let declared = concatMap C.unitDeclarations (C.programUnits other)
            identifiers = map C.declarationName declared
        length identifiers `shouldBe` length (nub identifiers)
        map (C.declarationName . C.definitionDeclaration) (definitions other) `shouldNotBe` names
