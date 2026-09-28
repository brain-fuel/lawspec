module DefinitionPredicateSpec (spec) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.Frontend (compileCore)
import LawSpec.Testing
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Scalar (Scalar(..))

-- Construct predicates at the public typed Core boundary. Source refinement
-- elaboration is a separate check; these tests cannot bypass Core validation.
fixture :: String -> (Program -> Expectation) -> Expectation
fixture body check = case compileCore 64 defaultGeneration [Source "predicate.lawspec" ("unit predicate\n" ++ body)] of
  Left diagnostics -> expectationFailure (show diagnostics)
  Right program -> check (mapProperties attach program)
  where
    attach property = case (propertyInputs property, propertyBody property) of
      ([q], Equation _ expression _) -> property
        { propertyInputs = [q{quantifiedPredicates=[expression]}]
        , propertyBody = Equation (Structural (scalarType "Bool")) truth truth
        }
      _ -> error "invalid predicate test fixture"
    truth = Expr (scalarType "Bool") (Constant (SBool True)) (GeneratedFrom (Id "predicate"))

mapProperties :: (Property -> Property) -> Program -> Program
mapProperties f program = program{programUnits=
  [u{unitProperties=map f (unitProperties u)} | u <- programUnits program]}

booleanSource :: String
booleanSource = "definition keep (x :: Bool) :: Bool is x end\n" ++
  "law `selected` is definition is `for all` (x :: Bool) . keep x = true end end"

spec :: Spec
spec = describe "closed definitions in Core predicates" $ do
  it "elaborates generic source calls in aliases, examples, and adapter contracts" $ do
    let source = Source "predicates.lawspec" $ unlines
          ["unit predicates"
          ,"definition nonempty (xs :: List a) :: Bool is match xs with | Nil -> false | Cons head tail -> true end end"
          ,"refinement Nonempty (T :: Type) is (xs :: List T where nonempty xs) end"
          ,"copy :: (xs :: Nonempty Int8) -> (result :: List Int8 where nonempty result)"
          ,"law `lists` is definition is `for all` (xs :: Nonempty Int8) . copy xs = xs end"
          ,"example `one` is xs = [1] expect copy xs = [1] end end"
          ,"law `text lists` is definition is `for all` (xs :: Nonempty Text) . xs = xs end end"]
    forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        length (concatMap unitDefinitions (programUnits program)) `shouldBe` 2
        case planTesting program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "rejects source examples outside a definition-backed domain" $ do
    let source value = Source "predicates.lawspec" $ unlines
          ["unit predicates"
          ,"definition positive (x :: a) :: Bool requires Integer a is x > 0 end"
          ,"law `positive` is definition is `for all` (x :: Int8 where positive x) . x = x end"
          ,"example `input` is x = " ++ value ++ " expect x = " ++ value ++ " end end"]
    compileCore 64 defaultGeneration [source "1"] `shouldSatisfy` isRight
    compileCore 64 defaultGeneration [source "0"] `shouldSatisfy` isLeft
  it "checks constant refinement arguments even without concrete examples" $ do
    let source value = Source "arguments.lawspec" $ unlines
          ["unit arguments"
          ,"definition positive (x :: a) :: Bool requires Integer a is x > 0 end"
          ,"refinement Positive is (x :: Int8 where positive x) end"
          ,"refinement Above (lower :: Positive) is (x :: Int8 where x > lower) end"
          ,"law `above` is definition is `for all` (x :: Above " ++ value ++ ") . x = x end end"]
    compileCore 64 defaultGeneration [source "1"] `shouldSatisfy` isRight
    compileCore 64 defaultGeneration [source "0"] `shouldSatisfy` isLeft
  it "resolves capabilities for generic definitions used only in postconditions" $ do
    let source = Source "contracts.lawspec" $ unlines
          ["unit contracts"
          ,"definition positive (x :: a) :: Bool requires Integer a is x > 0 end"
          ,"produce :: Unit -> (result :: Int8 where positive result)"]
    case compileCore 64 defaultGeneration [source] >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "enumerates finite domains through a validated definition and emits all targets" $
    fixture booleanSource $ \program -> do
      validateProgram program `shouldBe` Right ()
      case planTesting program of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> do
          let properties = concatMap plannedProperties (plannedUnits plan)
          map finiteCases properties `shouldBe` [Just [[ScalarValue (SBool True)]]]
          map boundaryCases properties `shouldBe` [[[ScalarValue (SBool True)]]]
          forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "evaluates recursive predicates on structural boundaries" $
    fixture ("definition allTrue (xs :: List Bool) :: Bool is match xs with | Nil -> true | Cons head tail -> head && allTrue tail end end\n" ++
      "law `selected` is definition is `for all` (xs :: List Bool) . allTrue xs = true end end") $ \program -> do
        case (planTesting program, prepareDefinitions program, makeRegistry []) of
          (Right plan, Right invoke, Right registry) -> do
            let properties = concatMap plannedProperties (plannedUnits plan)
                qs = propertyInputs (plannedProperty (head properties))
                ty = Constructor "List" [TypeArgument (scalarType "Bool")]
                nil = DataValue ty (Id "List::Nil") []
                cons flag tail = DataValue ty (Id "List::Cons") [ScalarValue (SBool flag),tail]
            validTupleWithDefinitions registry 64 invoke qs [nil] `shouldBe` Right True
            validTupleWithDefinitions registry 64 invoke qs [cons True nil] `shouldBe` Right True
            validTupleWithDefinitions registry 64 invoke qs [cons True (cons False nil)] `shouldBe` Right False
            map finiteCases properties `shouldBe` [Nothing]
          _ -> expectationFailure "recursive definition predicate failed validation or planning"
  it "rejects adapter calls, including calls behind a false guard" $
    fixture ("adapter :: Bool -> Bool\nlaw `selected` is definition is `for all` (x :: Bool) . false && adapter x = true end end") $ \program -> do
      validateProgram program `shouldSatisfy` isLeft
      planTesting program `shouldSatisfy` isLeft
  it "rejects unsafe definition bodies before evaluating the domain" $
    fixture booleanSource $ \program -> do
      let corrupt d = d{definitionBody=Expr (scalarType "Bool")
            (ExternalCall (declarationId (definitionDeclaration d))
              [Expr (scalarType "Bool") (Local (binderId (head (definitionArguments d))))
                (GeneratedFrom (Id "unsafe"))]) (GeneratedFrom (Id "unsafe"))}
          unsafe = program{programUnits=[u{unitDefinitions=map corrupt (unitDefinitions u)} | u <- programUnits program]}
      validateProgram unsafe `shouldSatisfy` isLeft
      planTesting unsafe `shouldSatisfy` isLeft
  it "rejects a finite domain with no satisfying tuples" $
    fixture ("definition keep (x :: Bool) :: Bool is false end\n" ++
      "law `selected` is definition is `for all` (x :: Bool) . keep x = true end end") $ \program ->
        planTesting program `shouldSatisfy` isLeft
  it "checks concrete example inputs against definition predicates" $
    fixture booleanSource $ \program -> do
      let example flag property = property{propertyExamples=[Example "input"
            [(binderId (quantifiedBinder (head (propertyInputs property))),
              Expr (scalarType "Bool") (Constant (SBool flag)) (GeneratedFrom (Id "input")))] []]}
      planTesting (mapProperties (example True) program) `shouldSatisfy` isRight
      planTesting (mapProperties (example False) program) `shouldSatisfy` isLeft
  it "keeps dependent predicates scoped to the generated prefix" $
    fixture booleanSource $ \program -> do
      let dependent property = case propertyInputs property of
            [first] -> property{propertyInputs=
              [first{quantifiedPredicates=[]}, first{quantifiedBinder=
                Binder (Id "second") "second" (scalarType "Bool")} ]}
            _ -> error "invalid dependent fixture"
      case planTesting (mapProperties dependent program) of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> map finiteCases (concatMap plannedProperties (plannedUnits plan)) `shouldBe`
          [Just [[ScalarValue (SBool True), ScalarValue (SBool False)],
                 [ScalarValue (SBool True), ScalarValue (SBool True)]]]
  it "accepts total calls in contracts and still rejects adapter calls there" $
    fixture booleanSource $ \program -> do
      let boolean = scalarType "Bool"
          origin = GeneratedFrom (Id "contract")
          adapter = Declaration (Id "predicate::adapter") "adapter" (Arrow boolean boolean) origin
          argument = Binder (Id "contract::argument") "argument" boolean
          result = Binder (Id "contract::result") "result" boolean
          call name value = Expr boolean (ExternalCall name [Expr boolean (Local (binderId value)) origin]) origin
          addContract name u = u{unitDeclarations=adapter:unitDeclarations u,
            unitContracts=[Contract (declarationId adapter) [argument] result
              [call name argument] [call name result]]}
          change name = program{programUnits=map (addContract name) (programUnits program)}
      validateProgram (change (Id "predicate::keep")) `shouldBe` Right ()
      validateProgram (change (declarationId adapter)) `shouldSatisfy` isLeft
