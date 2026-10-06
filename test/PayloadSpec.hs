module PayloadSpec (spec) where

import Test.Hspec
import Control.Monad (forM_)
import qualified Data.Map.Strict as M
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.Char8 as BL
import LawSpec.Common
import qualified LawSpec.Model as S
import qualified LawSpec.Inference as I
import qualified LawSpec.Elaboration as E
import LawSpec.Compile (validateDefinitionTotality)
import LawSpec.SpecializeDefinitions (specializeDefinitions)
import LawSpec.Core.Expression
import LawSpec.Core.Eval
import LawSpec.Core.Total (validateDefinitions)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.CoreEmit (emitPlan, targets)
import qualified LawSpec.Testing as Testing
import qualified LawSpec.Public as Public
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import LawSpec.Core
import LawSpec.Core.Payload
import LawSpec.Core.Types
import LawSpec.Core.Value
import LawSpec.Scalar (Scalar(..))

origin = GeneratedFrom (Id "payload-test")
parameter name = TypeVariable (Id name)
app name arguments = Constructor name (map TypeArgument arguments)
int = scalarType "Int8"
integer n = ScalarValue (SInteger "Int8" n)
variant owner name fields = DataConstructor (Id (owner ++ "::" ++ name)) name
  [Binder (Id (owner ++ "::" ++ name ++ "::" ++ field)) field ty | (field,ty) <- fields]
  [] origin [] []
structure name parameters constructors = DataDeclaration (Id name) name
  (map Id parameters) constructors origin Nothing
right = either error id
positive (ScalarValue (SInteger "Int8" n)) = Right (n > 0)
positive _ = Left "wrong positive payload type"
negative (ScalarValue (SInteger "Int8" n)) = Right (n < 0)
negative _ = Left "wrong negative payload type"

spec :: Spec
spec = describe "recursive parameter payload traversal" $ do
  let tree = structure "Tree" ["a"]
        [variant "Tree" "Leaf" [("value", parameter "a"), ("fixed", int)],
         variant "Tree" "Branch" [("children", app "List" [app "Tree" [parameter "a"]])]]
      treeType = app "Tree" [int]
      leaf n = DataValue treeType (Id "Tree::Leaf") [integer n, integer (-128)]
      branch children = DataValue treeType (Id "Tree::Branch")
        [listValue treeType children]
      registry = right (makeRegistry [tree])
      run = checkPayloads (validateValue registry 64) registry treeType [positive]
  it "types and lowers scoped surface payload predicates to executable Core" $ do
    let source = S.AllPayloadsExpr (S.Var "tree")
          [("member",S.Binary ">" (S.Var "member") (S.Number 0))]
        env = [("tree",S.Applied "Tree" (S.Named "Int8"))]
    forM_ [32,64] $ \bits -> case E.elaborateResolvedWithData [tree] [] bits
        (Id "surface") Id env source of
      Left message -> expectationFailure message
      Right expression -> do
        validateExpressionWithRegistry registry bits M.empty (M.singleton (Id "tree") treeType)
          expression `shouldBe` Right ()
        evaluateValuePure registry bits [(Id "tree",branch [leaf 1,leaf 2])] expression
          `shouldBe` Right (ScalarValue (SBool True))
        evaluateValuePure registry bits [(Id "tree",branch [leaf 1,leaf 0])] expression
          `shouldBe` Right (ScalarValue (SBool False))
  it "keeps identically named sibling callbacks independently typed and scoped" $ do
    let source = S.AllPayloadsExpr (S.Var "pair")
          [("member",S.Binary ">" (S.Var "member") (S.Number 0)),
           ("member",S.Var "member")]
        env = [("pair",S.Application "Either" [S.Named "Int8",S.Named "Bool"])]
    case E.elaborateResolvedWithData [] [] 64 (Id "surface") Id env source of
      Left message -> expectationFailure message
      Right expression -> case expressionNode expression of
        AllPayloads _ [(first,_),(second,_)] -> do
          binderId first `shouldNotBe` binderId second
          binderType first `shouldBe` int
          binderType second `shouldBe` scalarType "Bool"
          validateExpressionWithRegistry (right (makeRegistry [])) 64 M.empty
            (M.singleton (Id "pair") (app "Either" [int,scalarType "Bool"])) expression
            `shouldBe` Right ()
        _ -> expectationFailure "missing lowered payload predicate"
  it "rejects malformed surface payload domains, callbacks and sibling references" $ do
    let env = [("tree",S.Applied "Tree" (S.Named "Int8")),
               ("pair",S.Application "Either" [S.Named "Int8",S.Named "Bool"]),
               ("scalar",S.Named "Int8")]
        check = I.typedExpressionWithData [tree] 64 env
    mapM_ (\expression -> check expression `shouldSatisfy` isLeft)
      [S.AllPayloadsExpr (S.Var "tree") [],
       S.AllPayloadsExpr (S.Var "tree") [("x",S.Number 1)],
       S.AllPayloadsExpr (S.Var "scalar") [],
       S.AllPayloadsExpr (S.Var "pair") [("x",S.BoolLit True),("y",S.Var "x")]]
  it "substitutes payload callbacks without capturing free variables" $ do
    let source = S.AllPayloadsExpr (S.Var "tree")
          [("member",S.Binary ">" (S.Var "member") (S.Var "limit")),
           ("limit",S.Binary "=" (S.Var "limit") (S.Var "limit"))]
        actual = S.replaceExprVars [("limit",S.Var "member")] source
    case actual of
      S.AllPayloadsExpr _ [(fresh,S.Binary ">" (S.Var bound) (S.Var free)),
                           ("limit",second)] -> do
        fresh `shouldNotBe` "member"
        bound `shouldBe` fresh
        free `shouldBe` "member"
        second `shouldBe` S.Binary "=" (S.Var "limit") (S.Var "limit")
        S.exprVars actual `shouldBe` ["tree","member"]
      _ -> expectationFailure (show actual)
  it "preserves payload contracts through template proofs and specialization" $ do
    let sourceType = S.Applied "Tree" (S.Named "Int8")
        refined name = S.Refined name sourceType (Just (S.AllPayloadsExpr (S.Var name)
          [("member",S.Binary ">" (S.Var "member") (S.Number 0))]))
        span = Span (Location "payload.lawspec" 1 1) (Location "payload.lawspec" 1 10)
        definition = S.FunctionDefinition "identity" [("tree",refined "tree")]
          (refined "result") [] (S.Var "tree") span
        unit = S.Unit "surface" [("identity",S.Arrow (refined "tree") (refined "result"))]
          [] [] [] [] [] [definition] [] [] [] [] [] [] [] [] [] [] [] [] [] [] Nothing [] []
        invalid = unit {S.functionDefinitions=[definition {S.functionBody=
          S.ConstructLit "Tree::Leaf" [S.Number 0,S.Number 0]}]}
    forM_ [32,64] $ \bits -> do
      validateDefinitionTotality [tree] bits unit `shouldBe` Right ()
      validateDefinitionTotality [tree] bits invalid `shouldSatisfy` isLeft
      case specializeDefinitions [tree] bits (const True) [unit] [] of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right ([specialized],[]) -> case E.elaborateDefinitionUnit [tree] bits specialized of
          Left message -> expectationFailure message
          Right core -> case prepareDefinitions (Program bits [tree] [core]) of
            Left diagnostics -> expectationFailure (show diagnostics)
            Right invoke -> do
              invoke (Id "surface::identity") [leaf 1] `shouldBe` Right (leaf 1)
              invoke (Id "surface::identity") [leaf 0] `shouldSatisfy` isLeft
        Right _ -> expectationFailure "unexpected specialization units"
  it "checks recursive occurrences without constraining unrelated fixed fields" $ do
    run (branch [leaf 1, branch [leaf 2]]) `shouldBe` Right True
    run (branch [leaf 1, branch [leaf 0]]) `shouldBe` Right False
    run (branch []) `shouldBe` Right True
  it "does not impose a type-unfolding depth limit" $ do
    let deep = iterate (branch . pure) (leaf 1) !! 80
    run deep `shouldBe` Right True
    run (iterate (branch . pure) (leaf 0) !! 80) `shouldBe` Right False
  it "keeps different parameter roles even at the same concrete type" $ do
    let pair = structure "Pair" ["a","b"]
          [variant "Pair" "Pair" [("first",parameter "a"), ("second",parameter "b")]]
        r = right (makeRegistry [pair])
        ty = app "Pair" [int,int]
        check x y = checkPayloads (validateValue r 64) r ty [positive,negative]
          (DataValue ty (Id "Pair::Pair") [integer x,integer y])
    check 1 (-1) `shouldBe` Right True
    check (-1) 1 `shouldBe` Right False
    check 1 1 `shouldBe` Right False
  it "tracks swapped parameters through mutually recursive declarations" $ do
    let left = structure "A" ["a","b"]
          [variant "A" "End" [("value",parameter "a")],
           variant "A" "Across" [("next",app "B" [parameter "b",parameter "a"])]]
        rightType = structure "B" ["x","y"]
          [variant "B" "Back" [("next",app "A" [parameter "y",parameter "x"])],
           variant "B" "End" [("value",parameter "x")]]
        r = right (makeRegistry [left,rightType])
        a = app "A" [int,int]
        b = app "B" [int,int]
        end n = DataValue a (Id "A::End") [integer n]
        across child = DataValue a (Id "A::Across") [child]
        check = checkPayloads (validateValue r 64) r a [positive,negative]
    check (across (DataValue b (Id "B::End") [integer (-1)])) `shouldBe` Right True
    check (across (DataValue b (Id "B::End") [integer 1])) `shouldBe` Right False
    check (across (DataValue b (Id "B::Back") [end 1])) `shouldBe` Right True
  it "follows growing type arguments using the stored value as the recursion bound" $ do
    let nest = structure "Nest" ["a"]
          [variant "Nest" "Stop" [("value",parameter "a")],
           variant "Nest" "Next" [("next",app "Nest" [app "List" [parameter "a"]])]]
        r = right (makeRegistry [nest])
        ty = app "Nest" [int]
        nested = app "Nest" [app "List" [int]]
        value ns = DataValue ty (Id "Nest::Next")
          [DataValue nested (Id "Nest::Stop") [listValue int (map integer ns)]]
        check = checkPayloads (validateValue r 64) r ty [positive]
    check (value [1,2]) `shouldBe` Right True
    check (value [1,0]) `shouldBe` Right False
    check (value []) `shouldBe` Right True
  it "traverses nested sums and presence while preserving absent states" $ do
    let inner = app "Nullable" [app "Maybe" [int]]
        ty = app "Either" [inner,int]
        r = right (makeRegistry [])
        some n = PresenceValue inner (Just
          (DataValue (app "Maybe" [int]) (Id "Maybe::Just") [integer n]))
        check p = checkPayloads (validateValue r 64) r ty
          [\value -> checkPayloads (validateValue r 64) r inner
            [\m -> checkPayloads (validateValue r 64) r (app "Maybe" [int]) [positive] m] value,
           negative] p
    check (DataValue ty (Id "Either::Left") [some 1]) `shouldBe` Right True
    check (DataValue ty (Id "Either::Left") [some 0]) `shouldBe` Right False
    check (DataValue ty (Id "Either::Left") [PresenceValue inner Nothing]) `shouldBe` Right True
    check (DataValue ty (Id "Either::Right") [integer (-1)]) `shouldBe` Right True
  it "composes stored container recipes without changing the leaf predicate" $ do
    let wrapped = structure "Wrapped" ["a"]
          [variant "Wrapped" "Wrap"
            [("payload",app "Optional" [app "Maybe" [parameter "a"]])]]
        r = right (makeRegistry [wrapped])
        ty = app "Wrapped" [int]
        optional = app "Optional" [app "Maybe" [int]]
        wrap value = DataValue ty (Id "Wrapped::Wrap") [value]
        some n = wrap (PresenceValue optional (Just
          (DataValue (app "Maybe" [int]) (Id "Maybe::Just") [integer n])))
        check = checkPayloads (validateValue r 64) r ty [positive]
    check (some 1) `shouldBe` Right True
    check (some 0) `shouldBe` Right False
    check (wrap (PresenceValue optional Nothing)) `shouldBe` Right True
    check (wrap (PresenceValue optional (Just
      (DataValue (app "Maybe" [int]) (Id "Maybe::Nothing") [])))) `shouldBe` Right True
  it "does not evaluate phantom predicates or unselected alternatives" $ do
    let phantom = structure "Phantom" ["a"] [variant "Phantom" "Tag" []]
        r = right (makeRegistry [phantom])
        ty = app "Phantom" [int]
    checkPayloads (validateValue r 64) r ty [const (Left "phantom evaluated")]
      (DataValue ty (Id "Phantom::Tag") []) `shouldBe` Right True
    let choice = app "Either" [int,int]
    checkPayloads (validateValue r 64) r choice [positive,const (Left "unused evaluated")]
      (DataValue choice (Id "Either::Left") [integer 1]) `shouldBe` Right True
  it "short-circuits rejection and retains contextual evaluation errors" $ do
    let checked (ScalarValue (SInteger "Int8" n))
          | n == 2 = Left "division diagnostic"
          | otherwise = positive (integer n)
        checked _ = Left "unexpected payload"
        check = checkPayloads (validateValue registry 64) registry treeType [checked]
    check (branch [leaf 0,leaf 2]) `shouldBe` Right False
    case check (branch [leaf 1,leaf 2]) of
      Left message -> do
        message `shouldSatisfy` isInfixOf "Tree::Leaf::value"
        message `shouldSatisfy` isInfixOf "division diagnostic"
      Right _ -> expectationFailure "evaluation error discarded"
  it "validates before running predicates and rejects arity mismatches" $ do
    run (DataValue treeType (Id "Tree::Leaf") [integer 1]) `shouldSatisfy` isLeft
    run (leaf 128) `shouldSatisfy` isLeft
    checkPayloads (validateValue registry 64) registry treeType [] (leaf 1)
      `shouldSatisfy` isLeft
    checkPayloads (\_ _ -> Left "constructor contract failed") registry treeType
      [const (Left "predicate ran before validation")] (leaf 1)
      `shouldBe` Left "constructor contract failed"

  describe "typed recursive payload predicates" $ do
    let boolean = scalarType "Bool"
        rootId = Id "root"
        thresholdId = Id "threshold"
        item = Binder (Id "payload") "item" int
        local name ty = Expr ty (Local name) origin
        constant n = Expr int (Constant (SInteger "Int8" n)) origin
        truth = Expr boolean (Constant (SBool True)) origin
        binary op left right = Expr
          (if isComparison op then boolean else scalarType "Rational")
          (Binary op (rightEvidence op left right) left right) origin
        rightEvidence op left right = either error id
          (operationEvidence op (expressionType left) (expressionType right))
        predicate = binary Greater (local (binderId item) int) (local thresholdId int)
        input = local rootId treeType
        expression ps = Expr boolean (AllPayloads input ps) origin
        term = expression [(item,predicate)]
        scope = M.fromList [(rootId,treeType),(thresholdId,int)]
        validate = validateExpressionWithRegistry registry 64 M.empty scope
        eval value = evaluateValuePure registry 64
          [(rootId,value),(thresholdId,integer 1)] term
    it "evaluates the typed operation with outer dependencies at every stored leaf" $ do
      validate term `shouldBe` Right ()
      eval (branch [leaf 2,branch [leaf 3]]) `shouldBe` Right (ScalarValue (SBool True))
      eval (branch [leaf 2,branch [leaf 1]]) `shouldBe` Right (ScalarValue (SBool False))
      eval (branch []) `shouldBe` Right (ScalarValue (SBool True))
    it "keeps payload arithmetic guarded and propagates evaluator faults" $ do
      let x = local (binderId item) int
          quotient = binary Divide (constant 1) x
          positiveQuotient = binary Greater quotient (constant 0)
          guarded = Expr boolean (ShortCircuit And
            (binary NotEqual x (constant 0)) positiveQuotient) origin
          evaluate p value = evaluateValuePure registry 64 [(rootId,value)]
            (expression [(item,p)])
      evaluate guarded (branch [leaf 0,leaf 1]) `shouldBe` Right (ScalarValue (SBool False))
      evaluate positiveQuotient (branch [leaf 0]) `shouldSatisfy` isLeft
    it "validates callback arity, types, result types and binder identities" $ do
      validate (expression []) `shouldSatisfy` isLeft
      validate (expression [(item{binderType=scalarType "Int16"},truth)]) `shouldSatisfy` isLeft
      validate (expression [(item,constant 1)]) `shouldSatisfy` isLeft
      validate (expression [(item{binderId=rootId},truth)]) `shouldSatisfy` isLeft
      validate term{expressionType=int} `shouldSatisfy` isLeft
      let scalar = Expr boolean (AllPayloads (constant 1) []) origin
      validate scalar `shouldSatisfy` isLeft
    it "isolates callback binders from their sibling callbacks" $ do
      let pair = structure "Pair" ["a","b"]
            [variant "Pair" "Pair" [("first",parameter "a"),("second",parameter "b")]]
          r = right (makeRegistry [pair])
          ty = app "Pair" [int,int]
          second = item{binderId=Id "second"}
          leaked = Expr boolean (AllPayloads (local rootId ty)
            [(item,binary Greater (local (binderId second) int) (constant 0)),
             (second,truth)]) origin
      validateExpressionWithRegistry r 64 M.empty (M.singleton rootId ty) leaked
        `shouldSatisfy` isLeft
      freeBinders leaked `shouldBe` [rootId,binderId second]
    it "exposes predicate children without leaking their bound identities" $ do
      children term `shouldBe` [input,predicate]
      freeBinders term `shouldBe` [rootId,thresholdId]
      isPure term `shouldBe` True
      isPure (expression [(item,Expr boolean (ExternalCall (Id "adapter") []) origin)])
        `shouldBe` False
    it "substitutes generic payload binders and scrutinee types" $ do
      let a = parameter "a"
          field = Binder (Id "Holder::Hold::value") "value" (app "Tree" [a])
          generic = Expr boolean (AllPayloads (local (binderId field) (binderType field))
            [(item{binderType=a},truth)]) origin
          holder = structure "Holder" ["a"]
            [DataConstructor (Id "Holder::Hold") "Hold" [field] [generic] origin [] []]
          r = right (makeRegistry [tree,holder])
      case constructorPredicatesFor r (app "Holder" [int]) (Id "Holder::Hold") of
        Right [Expr _ (AllPayloads value [(binder,_)]) _] -> do
          expressionType value `shouldBe` treeType
          binderType binder `shouldBe` int
        result -> expectationFailure (show result)
    it "serializes the ordered callbacks with their local names and types" $ do
      let encoded = BL.unpack (A.encode (Public.expressionView [(rootId,"tree")] term))
      encoded `shouldSatisfy` isInfixOf "\"kind\":\"allPayloads\""
      encoded `shouldSatisfy` isInfixOf "\"predicates\""
      encoded `shouldSatisfy` isInfixOf "\"name\":\"item\""
    it "admits total payload predicates after auditing their callbacks" $ do
      let body = expression [(item,binary Greater (local (binderId item) int) (constant 0))]
          declaration = Declaration (Id "check") "check" (Arrow treeType boolean) origin
          definition = Definition declaration [Binder rootId "tree" treeType] body
      validateDefinitions 64 [tree] [definition] `shouldSatisfy` isRight
    it "emits payload predicates on all eight targets" $ do
      let body = expression [(item,truth)]
          property = Property (Id "payload::law::payload") "payload" (Location "payload" 1 1)
            [Quantifier (Binder rootId "tree" treeType) [] []]
            (Equation (Structural boolean) body truth) [] defaultGeneration "" "" [] [] [] [] noHarness
          unit = Unit (Id "payload") [] [] [property] [] []
          plan = Testing.Plan 64 [tree]
            [Testing.PlannedUnit unit [Testing.PlannedProperty property Nothing [] []]]
      forM_ targets $ \target ->
        emitPlan target plan `shouldSatisfy` isRight
