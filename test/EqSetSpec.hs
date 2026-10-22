-- | Canonical sets compare by Eq membership while retaining insertion order.
-- These Core checks precede authoring exposure and native integration.
module EqSetSpec (test_eqOnlySetsPreserveMembershipAndIteration) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (permutations, subsequences, nub)
import qualified Data.Map.Strict as M
import Test.Hspec
import LawSpec.Core
import qualified LawSpec.Core.EqSet as Set
import LawSpec.Core.Eval (evaluateValuePure)
import LawSpec.Core.Types
import LawSpec.Core.Value
import LawSpec.Scalar
import qualified LawSpec.Typed.Plan as Typed
import LawSpec.Frontend (compileCore)
import qualified LawSpec.Model as Source
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Testing (planTesting, finiteValuesWithRegistry)
import LawSpec.CoreEmit (emitPlan,targets)

origin :: Origin
origin = GeneratedFrom (Id "eq-set-regression")
integer, float :: Type
integer = scalarType "Integer"
float = scalarType "Float64"
setType :: Type -> Type
setType element = Constructor (idText Set.eqSetTypeId) [TypeArgument element]
set :: Type -> [Value] -> Value
set element values = DataValue (setType element) Set.eqSetConstructorId [listValue element values]
number :: Integer -> Value
number = ScalarValue . SInteger "Integer"
registry :: [DataDeclaration] -> IO TypeRegistry
registry extra = either (\message -> expectationFailure message >> fail message) pure
  (makeRegistry (Set.eqSetDeclaration : extra))

test_eqOnlySetsPreserveMembershipAndIteration :: Spec
test_eqOnlySetsPreserveMembershipAndIteration = describe "Eq-only set Core semantics" $ do
  it "compares every permutation extensionally and keeps stored iteration order" $ do
    r <- registry []
    forM_ (permutations [number 1,number 2,number 3]) $ \values -> do
      let value = set integer values
      validateValue r 64 (setType integer) value `shouldBe` Right value
      case value of
        DataValue _ _ [items] -> listItems items `shouldBe` Right values
        _ -> expectationFailure "invalid fixture"
      forM_ (permutations [number 1,number 2,number 3]) $ \other ->
        equalValues 64 value (set integer other) `shouldBe` Right True
  it "distinguishes empty, missing, extra and different members" $ do
    equalValues 64 (set integer []) (set integer []) `shouldBe` Right True
    forM_ [[],[number 1],[number 1,number 3],[number 1,number 2,number 3]] $ \other ->
      equalValues 64 (set integer [number 1,number 2]) (set integer other) `shouldBe` Right False
  it "rejects duplicate Eq members at construction and validation boundaries" $ do
    r <- registry []
    let bad = set integer [number 1,number 2,number 1]
    validateValue r 64 (setType integer) bad `shouldSatisfy` isLeft
    let item = Expr integer (Constant (SInteger "Integer" 1)) origin
        nil = Expr (Constructor "List" [TypeArgument integer]) (Construct (Id "List::Nil") []) origin
        cons x xs = Expr (expressionType nil) (Construct (Id "List::Cons") [x,xs]) origin
        expression = Expr (setType integer) (Construct Set.eqSetConstructorId [cons item (cons item nil)]) origin
    evaluateValuePure r 64 [] expression `shouldSatisfy` isLeft
  it "uses IEEE equality for duplicates and never equates a NaN to itself" $ do
    r <- registry []
    let nan = ScalarValue (SFloat "Float64" "7ff8000000000001")
        positiveZero = ScalarValue (SFloat "Float64" "0000000000000000")
        negativeZero = ScalarValue (SFloat "Float64" "8000000000000000")
        value = set float [nan,nan]
    validateValue r 64 (setType float) value `shouldBe` Right value
    equalValues 64 value value `shouldBe` Right False
    equalValues 64 (set float [positiveZero]) (set float [negativeZero]) `shouldBe` Right True
    validateValue r 64 (setType float) (set float [positiveZero,negativeZero]) `shouldSatisfy` isLeft
  it "uses symbol identity without introducing an ordering requirement" $ do
    r <- registry []
    let symbol = scalarType "Symbol"
        one = ScalarValue (SSymbol "one" "same description")
        two = ScalarValue (SSymbol "two" "same description")
    validateValue r 64 (setType symbol) (set symbol [one,two]) `shouldBe` Right (set symbol [one,two])
    equalValues 64 (set symbol [one,two]) (set symbol [two,one]) `shouldBe` Right True
    equalValues 64 (set symbol [one]) (set symbol [two]) `shouldBe` Right False
    validateValue r 64 (setType symbol) (set symbol [one,one]) `shouldSatisfy` isLeft
  it "compares sets inside products, alternatives, lists, and presence recursively" $ do
    let a = set integer [number 1,number 2]
        b = set integer [number 2,number 1]
        box = scalarType "Box"
        wrap x = DataValue box (Id "Box::Wrap") [x]
        maybeType = Constructor "Maybe" [TypeArgument (setType integer)]
        optionalType = Constructor "Optional" [TypeArgument (setType integer)]
    equalValues 64 (wrap a) (wrap b) `shouldBe` Right True
    equalValues 64 (listValue (setType integer) [a,b]) (listValue (setType integer) [b,a]) `shouldBe` Right True
    equalValues 64 (DataValue maybeType (Id "Maybe::Present") [a]) (DataValue maybeType (Id "Maybe::Present") [b]) `shouldBe` Right True
    equalValues 64 (PresenceValue optionalType (Just a)) (PresenceValue optionalType (Just b)) `shouldBe` Right True
    equalValues 64 (set (setType integer) [a]) (set (setType integer) [b]) `shouldBe` Right True
  it "rejects nested duplicate sets according to their extensional equality" $ do
    r <- registry []
    let a = set integer [number 1,number 2]
        b = set integer [number 2,number 1]
    validateValue r 64 (setType (setType integer)) (set (setType integer) [a,b]) `shouldSatisfy` isLeft
  it "requires Eq only and does not derive Keyed from storage order" $ do
    let parameter = Id "Box::a"
        box = DataDeclaration (Id "Box") "Box" [parameter]
          [DataConstructor (Id "Box::Wrap") "Wrap" [Binder (Id "Box::value") "value" (TypeVariable parameter)] [] origin [] []] origin Nothing
    r <- registry [box]
    equalityRequirements r (setType float) `shouldBe` Right []
    equalityRequirements r (setType (TypeVariable parameter)) `shouldBe` Right [parameter]
    equalityRequirements r (setType (Arrow integer integer)) `shouldSatisfy` isLeft
    forM_ [setType integer, Constructor "List" [TypeArgument (setType integer)],
        Constructor "Box" [TypeArgument (setType integer)]] $ \ty ->
      keyedRequirements r ty `shouldSatisfy` isLeft
    compareValues (set integer []) (set integer []) `shouldSatisfy` isLeft
  it "uses the same set equality in typed Core evaluation" $ do
    r <- registry []
    let ty = setType integer
        left = Expr ty (Local (Id "left")) origin
        right = Expr ty (Local (Id "right")) origin
        expression = Expr (scalarType "Bool") (Binary Equal (Structural ty) left right) origin
    evaluateValuePure r 64 [(Id "left",set integer [number 1,number 2]),(Id "right",set integer [number 2,number 1])] expression
      `shouldBe` Right (ScalarValue (SBool True))
  it "refuses a forged shape or constructor owner for the reserved identity" $ do
    let declaration = Set.eqSetDeclaration
        constructor = head (dataConstructors declaration)
    forM_ [declaration{dataParameters=[]},declaration{dataConstructors=[]},
        declaration{dataConstructors=[constructor{constructorFields=[]}]},
        declaration{dataConstructors=[constructor{constructorId=Id "other"}]},
        declaration{dataHandle=True}] $ \bad -> fmap (const ()) (makeRegistry [bad]) `shouldSatisfy` isLeft
    let other = declaration{dataId=Id "Other"}
    fmap (const ()) (makeRegistry [other]) `shouldSatisfy` isLeft
  it "keeps ordinary List equality ordered" $
    equalValues 64 (listValue integer [number 1,number 2]) (listValue integer [number 2,number 1]) `shouldBe` Right False
  it "keeps set-bearing definitions on the checked value path" $ do
    let definition name ty =
          let declaration = Declaration (Id name) name (Arrow ty ty) origin
              argument = Binder (Id (name ++ "::value")) "value" ty
          in Definition declaration [argument] (Expr ty (Local (binderId argument)) origin)
        defs = [definition "setIdentity" (setType integer), definition "integerIdentity" integer]
        unit = Unit (Id "set-plan") (map definitionDeclaration defs) [] [] defs []
        plan = Typed.typedPlan [Set.eqSetDeclaration] [unit]
    M.member (Id "setIdentity") (Typed.typedDefinitions plan) `shouldBe` False
    M.member (Id "integerIdentity") (Typed.typedDefinitions plan) `shouldBe` True
  it "enumerates every Boolean storage order and respects exact expansion budgets" $ do
    r <- registry []
    let boolean = scalarType "Bool"
        value = set boolean . map (ScalarValue . SBool)
        expected = map value [[],[False],[True],[False,True],[True,False]]
    forM_ [32,64] $ \bits -> do
      finiteValuesWithRegistry r bits 5 (setType boolean) `shouldSatisfy`
        (\result -> case result of Right (Just values) -> length values == 5 && all (`elem` values) expected; _ -> False)
      finiteValuesWithRegistry r bits 4 (setType boolean) `shouldBe` Right Nothing
      finiteValuesWithRegistry r bits 0 (setType boolean) `shouldBe` Right Nothing
  it "preserves equal elements with different stored orders in nested finite sets" $ do
    r <- registry []
    let boolean = scalarType "Bool"
        orders = [[],[False],[True],[False,True],[True,False]]
        masks = map (sum . map (\b -> if b then 2 else 1)) orders
        indexes = [xs | chosen <- subsequences [0..4], xs <- permutations chosen,
          let keys = map (masks !!) xs, length keys == length (nub keys)]
        inner = map (set boolean . map (ScalarValue . SBool)) orders
        expected = [set (setType boolean) (map (inner !!) xs) | xs <- indexes]
    length expected `shouldBe` 114
    case finiteValuesWithRegistry r 64 114 (setType (setType boolean)) of
      Right (Just values) -> values `shouldMatchList` expected
      other -> expectationFailure (show other)
    finiteValuesWithRegistry r 64 113 (setType (setType boolean)) `shouldBe` Right Nothing
  it "retains the empty set over an empty element type" $ do
    let empty = DataDeclaration (Id "Empty") "Empty" [] [] origin Nothing
        ty = Constructor "Empty" []
    r <- registry [empty]
    finiteValuesWithRegistry r 64 1 (setType ty) `shouldBe` Right (Just [set ty []])
  it "never presents non-reflexive repetition or a bounded prefix as a complete domain" $ do
    let equal a b = Right (a == b && a /= (0 :: Int)) :: Either String Bool
    Set.finiteMemberSequences 100 equal [0,1] `shouldBe` Right Nothing
    Set.finiteMemberSequences 1 equal [] `shouldBe` Right (Just [[]])
    Set.finiteMemberSequences 0 equal [] `shouldBe` Right Nothing
    Set.finiteMemberSequences 100 (\_ _ -> Left "comparison failed" :: Either String Bool) [1 :: Int]
      `shouldBe` Left "comparison failed"
  it "checks the internal representation's outcome laws and emits every target" $ do
    content <- readFile "test/fixtures/eq-set-foundation.lawspec"
    forM_ [32,64] $ \bits ->
      case compileCore bits Source.defaultGeneration [Source.Source "eq-set-foundation.lawspec" content] of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right program -> do
          dischargeEvidence program `shouldSatisfy` isRight
          case planTesting program of
            Left diagnostics -> expectationFailure (show diagnostics)
            Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
