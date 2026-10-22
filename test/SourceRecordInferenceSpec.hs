-- | Closed structural products retain their intrinsic constraints through
-- contextual inference. Checked construction is still admitted by Core.
-- ref:DEC-typed-core-boundary ref:DEC-readable-notation
module SourceRecordInferenceSpec (test_recordInferencePreservesClosedShapes) where

import Control.Monad.State.Strict (evalStateT)
import Data.Either (isLeft,isRight)
import qualified Data.Map.Strict as M
import Test.Hspec
import qualified LawSpec.Inference as I
import qualified LawSpec.Model as S
import LawSpec.Scalar (Scalar(..))

integer, small, boolean :: S.Type
integer=S.Named "Integer"
small=S.Named "UInt8"
boolean=S.Named "Bool"
field name=S.RecordField name name
record fields=S.Record [field name ty | (name,ty)<-fields]
positive binder=S.Refined binder (S.Named "BigUInt") (Just (S.Binary ">" (S.Var binder) (S.Number 0)))
get label value=S.Apply (S.Var (S.fieldAccessPrefix++label)) value
put label value replacement=S.Apply (S.Apply (S.Var (S.fieldUpdatePrefix++label)) value) replacement
literal=S.RecordLit
shape=record [("count",small),("enabled",boolean)]
reverseShape=record [("enabled",boolean),("count",small)]
typed=I.typedExpression 64
unified a b=evalStateT (I.unify a b) (I.initialState 64)
verify environment expression check=case typed environment expression of
 Left message->expectationFailure message
 Right tree->check tree

test_recordInferencePreservesClosedShapes :: Spec
test_recordInferencePreservesClosedShapes=describe "source record inference" $ do
 it "infers closed literals without sorting their evaluation operands" $
  verify [] (literal [("enabled",S.BoolLit True),("count",S.Number 1)]) $ \tree->do
   S.expressionType tree `shouldBe` record [("enabled",boolean),("count",integer)]
   map S.expression (S.operands tree) `shouldBe` [S.BoolLit True,S.Number 1]
 it "uses exact scalar context by label while retaining literal field order" $
  verify [] (S.Annotate (literal [("enabled",S.BoolLit True),("count",S.Number 255)]) shape) $ \tree->
   case S.operands tree of
    [inner]->do
     S.expressionType inner `shouldBe` shape
     map S.expressionType (S.operands inner) `shouldBe` [boolean,small]
    _->expectationFailure "lost contextual record literal"
 it "rejects out-of-range contextual record fields" $
  typed [] (S.Annotate (literal [("count",S.Number 256),("enabled",S.BoolLit True)]) shape) `shouldSatisfy` isLeft
 it "requires the exact field set and rejects repeated literal labels" $ do
  typed [] (S.Annotate (literal [("count",S.Number 1)]) shape) `shouldSatisfy` isLeft
  typed [] (S.Annotate (literal [("count",S.Number 1),("enabled",S.BoolLit True),("extra",S.Number 0)]) shape) `shouldSatisfy` isLeft
  typed [] (literal [("count",S.Number 1),("count",S.Number 2)]) `shouldSatisfy` isLeft
 it "keeps empty products as a distinct closed shape" $ do
  verify [] (literal []) $ \tree->S.expressionType tree `shouldBe` S.Record []
  unified (S.Record []) (record [("count",integer)]) `shouldSatisfy` isLeft
  unified (S.Record []) (S.Named "Unit") `shouldSatisfy` isLeft
 it "unifies field-order permutations without converting existing records" $ do
  unified shape reverseShape `shouldBe` Right ()
  verify [("value",shape)] (S.Annotate (S.Var "value") reverseShape) $ \tree->
   case S.operands tree of
    [inner]->S.requiredConversion inner `shouldBe` Nothing
    _->expectationFailure "lost record annotation"
 it "compares existing records in different field orders through one Eq requirement" $
  case I.typedExpressionWithSchemes [] 64 (I.monoEnvironment [("a",shape),("b",reverseShape)])
    (S.Binary "==" (S.Var "a") (S.Var "b")) of
   Left message->expectationFailure message
   Right (tree,requirements)->do
    S.expressionType tree `shouldBe` boolean
    requirements `shouldBe` [S.Capability "Eq" shape]
    map S.requiredConversion (S.operands tree) `shouldBe` [Nothing,Nothing]
 it "contextualizes opposite literals including nested record and sum payloads" $ do
  let left=literal [("inner",literal [("count",S.Number 1)]),("optional",S.ConstructLit "Absent" [])]
      right=literal [("optional",S.ConstructLit "Present" [S.BoolLit True]),
        ("inner",literal [("count",S.ScalarLit (SInteger "UInt8" 1))])]
  typed [] (S.Binary "==" left right) `shouldSatisfy` isRight
 it "does not widen or narrow a whole existing product implicitly" $ do
  unified (record [("count",integer)]) (record [("count",small)]) `shouldSatisfy` isLeft
  typed [("value",record [("count",integer)])] (S.Annotate (S.Var "value") (record [("count",small)])) `shouldSatisfy` isLeft
 it "does not unwrap or coerce a nominal product" $ do
  unified shape (S.Named "Picture") `shouldSatisfy` isLeft
  typed [] (S.Annotate (literal [("count",S.Number 1)]) (S.Named "Picture")) `shouldSatisfy` isLeft
 it "projects fields from known structural types and rejects unknown labels" $ do
  verify [("value",shape)] (get "count" (S.Var "value")) $ \tree->S.expressionType tree `shouldBe` small
  typed [("value",shape)] (get "missing" (S.Var "value")) `shouldSatisfy` isLeft
 it "projects nested products without introducing nominal identities" $ do
  let outer=record [("inner",shape)]
  verify [("value",outer)] (get "enabled" (get "inner" (S.Var "value"))) $ \tree->S.expressionType tree `shouldBe` boolean
 it "types an update in its existing product context" $ do
  verify [("value",shape)] (put "count" (S.Var "value") (S.Number 255)) $ \tree->do
   S.expressionType tree `shouldBe` shape
   map S.expressionType (S.operands tree) `shouldBe` [shape,small]
  typed [("value",shape)] (put "count" (S.Var "value") (S.Number 256)) `shouldSatisfy` isLeft
  typed [("value",shape)] (put "missing" (S.Var "value") (S.Number 1)) `shouldSatisfy` isLeft
 it "freshens polymorphic record fields independently for each use" $ do
  let template=record [("value",S.Variable "a")]
      environment=M.singleton "wrap" (I.Universal ["a"] [] (S.Arrow (S.Variable "a") template))
      expression=S.Binary "&&" (get "value" (S.Apply (S.Var "wrap") (S.BoolLit True)))
        (S.Binary "==" (get "value" (S.Apply (S.Var "wrap") (S.StringLit "text"))) (S.StringLit "text"))
  I.typedExpressionWithSchemes [] 64 environment expression `shouldSatisfy` isRight
 it "preserves repeated type-variable relationships across stored fields" $ do
  let template=record [("first",S.Variable "a"),("second",S.Variable "a")]
      environment=M.singleton "pair" (I.Universal ["a"] [] (S.Arrow template boolean))
  I.typedExpressionWithSchemes [] 64 environment
    (S.Apply (S.Var "pair") (literal [("first",S.Number 1),("second",S.BoolLit True)])) `shouldSatisfy` isLeft
 it "retains intrinsic field restrictions and allows binder alpha-renaming" $ do
  unified (record [("count",positive "count")]) (record [("count",positive "number")]) `shouldBe` Right ()
  unified (record [("count",positive "count")]) (record [("count",S.Named "BigUInt")]) `shouldSatisfy` isLeft
  verify [] (S.Annotate (literal [("count",S.Number 1)]) (record [("count",positive "n")])) $ \tree->
   S.expressionType tree `shouldBe` record [("count",positive "n")]
 it "preserves left-to-right dependent field restrictions under alpha-renaming" $ do
  let dependent first second=S.Record [S.RecordField "width" first integer,
        S.RecordField "height" second (S.Refined "v" integer (Just (S.Binary ">" (S.Var "v") (S.Var first))))]
  unified (dependent "width" "height") (dependent "x" "y") `shouldBe` Right ()
  unified (dependent "width" "height") (record [("width",integer),("height",integer)]) `shouldSatisfy` isLeft
 it "substitutes resolved type variables through intrinsic field restrictions" $ do
  let original=record [("value",S.Refined "v" (S.Variable "a") (Just
        (S.Binary "==" (S.Annotate (S.Var "v") (S.Variable "a")) (S.Annotate (S.Var "v") (S.Variable "a")))))]
      action=I.unify (S.Variable "a") integer >> I.resolve original
  case evalStateT action (I.initialState 64) of
   Left message->expectationFailure message
   Right result->result `shouldBe` S.mapType (\ty->if ty==S.Variable "a" then integer else ty)
      (S.mapExprTypes (\ty->if ty==S.Variable "a" then integer else ty)) original
 it "rejects infinite record substitutions and malformed type fields" $ do
  unified (S.Variable "a") (record [("self",S.Variable "a")]) `shouldSatisfy` isLeft
  let annotated=record [("value",S.Refined "v" integer (Just (S.Annotate (S.BoolLit True) (S.Variable "a"))))]
  unified (S.Variable "a") annotated `shouldSatisfy` isLeft
  let duplicate=record [("value",integer),("value",integer)]
  unified duplicate duplicate `shouldSatisfy` isLeft
 it "keeps record annotation constraints separate from unchecked outer refinements" $
  typed [] (S.Annotate (literal []) (S.Refined "value" (S.Record []) (Just (S.BoolLit True)))) `shouldSatisfy` isLeft
