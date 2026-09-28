module InferenceSchemeSpec (spec) where

import Test.Hspec
import Control.Monad.State.Strict (evalStateT)
import Data.Either (isLeft)
import qualified Data.Map.Strict as M
import qualified LawSpec.Inference as I
import LawSpec.Model

spec :: Spec
spec = describe "declaration type schemes" $ do
  let a = Variable "a"
      boolean = Named "Bool"
      text = Named "Text"
      int8 = Named "Int8"
      identity = I.Universal ["a"] [] (Arrow a a)
      env = M.singleton "identity" identity
      call name = Apply (Var name)
      typed = I.typedExpressionWithSchemes [] 64
      uses name tree = [expressionType tree | Var n <- [expression tree], n == name] ++
        concatMap (uses name) (operands tree) ++
        concat [uses name body | TypedCase _ _ body <- typedCases tree]
      verify environment expression check = case typed environment expression of
        Left message -> expectationFailure message
        Right result -> check result
  it "keeps internal List predicate substitution capture-free" $ do
    let original = AllElementsExpr (Var "xs") "element" (Binary ">" (Var "element") (Var "floor"))
        changed = replaceExprVars [("floor",Var "element")] original
    exprVars changed `shouldBe` ["xs","element"]
    case changed of
      AllElementsExpr _ binder _ -> binder `shouldNotBe` "element"
      _ -> expectationFailure "lost List predicate scope"
  it "types internal List predicates and rejects non-Bool bodies" $ do
    let listEnv = M.singleton "xs" (I.Monomorphic (Applied "List" int8))
    verify listEnv (AllElementsExpr (Var "xs") "item" (Binary ">" (Var "item") (Number 0))) $ \(tree, _) ->
      expressionType tree `shouldBe` boolean
    typed listEnv (AllElementsExpr (Var "xs") "item" (Var "item")) `shouldSatisfy` isLeft
  it "instantiates each use independently in one expression" $ do
    let expression = Binary "&&" (call "identity" (BoolLit True))
          (Binary "==" (call "identity" (StringLit "value")) (StringLit "value"))
    verify env expression $ \(tree, _) -> do
      expressionType tree `shouldBe` boolean
      uses "identity" tree `shouldBe` [Arrow boolean boolean, Arrow text text]
  it "keeps curried arguments in the same instantiation" $ do
    let constEnv = M.singleton "constant" (I.Universal ["a", "b"] []
          (Arrow a (Arrow (Variable "b") a)))
    verify constEnv (Apply (call "constant" (BoolLit True)) (StringLit "ignored")) $ \(tree, _) -> do
      expressionType tree `shouldBe` boolean
      uses "constant" tree `shouldBe` [Arrow boolean (Arrow text boolean)]
    typed env (Apply (call "identity" (BoolLit True)) (StringLit "invalid")) `shouldSatisfy` isLeft
  it "uses result annotations to resolve empty container arguments" $
    verify env (Annotate (call "identity" (ListLit [])) (Applied "List" int8)) $ \(tree, _) ->
      uses "identity" tree `shouldBe` [Arrow (Applied "List" int8) (Applied "List" int8)]
  it "resolves each member of a generic composition" $
    verify env (Annotate (Compose (Var "identity") (Var "identity")) (Arrow int8 int8)) $ \(tree, _) ->
      uses "identity" tree `shouldBe` replicate 2 (Arrow int8 int8)
  it "preserves free monomorphic variables while freshening bound ones" $ do
    let scheme = I.Universal ["a"] [] (Arrow a (Variable "shared"))
        expression = Binary "&&" (call "f" (BoolLit True)) (call "f" (StringLit "value"))
    verify (M.singleton "f" scheme) expression $ \(tree, _) ->
      uses "f" tree `shouldBe` [Arrow boolean boolean, Arrow text boolean]
  it "does not generalize ordinary function parameters" $ do
    let monomorphic = I.monoEnvironment [("f", Arrow a a)]
        expression = Binary "&&" (call "f" (BoolLit True))
          (Binary "==" (call "f" (StringLit "value")) (StringLit "value"))
    typed monomorphic expression `shouldSatisfy` isLeft
  it "keeps a match binder monomorphic when it shadows a declaration" $ do
    let scope = M.insert "xs" (I.Monomorphic (Applied "List" boolean)) env
        expression = MatchExpr (Var "xs")
          [MatchBranch "Nil" [] (BoolLit True),
           MatchBranch "Cons" ["identity", "rest"] (call "identity" (BoolLit True))]
    typed scope expression `shouldSatisfy` isLeft
  it "carries instantiated capability obligations with the typed tree" $ do
    let constrained = M.singleton "identity" (I.Universal ["a"] [Capability "Eq" a] (Arrow a a))
    verify constrained (call "identity" (BoolLit True)) $ \(_, requirements) ->
      requirements `shouldBe` [Capability "Eq" boolean]
  it "keeps a capability obligation for each independent instantiation" $ do
    let constrained = M.singleton "identity" (I.Universal ["a"] [Capability "Eq" a] (Arrow a a))
        expression = Binary "&&" (call "identity" (BoolLit True))
          (Binary "==" (call "identity" (StringLit "value")) (StringLit "value"))
    verify constrained expression $ \(_, requirements) -> do
      requirements `shouldMatchList` [Capability "Eq" boolean, Capability "Eq" text]
      requirements `shouldSatisfy` all (\(Capability _ ty) -> ty `elem` [boolean, text])
  it "does not freshen repeated parameters within a single signature" $ do
    let same = M.singleton "same" (I.Universal ["a"] [] (Arrow a (Arrow a boolean)))
    typed same (Apply (call "same" (BoolLit True)) (StringLit "value")) `shouldSatisfy` isLeft
  it "rejects duplicate quantified variables" $
    evalStateT (I.instantiate (I.Universal ["a", "a"] [] (Arrow a a))) (I.initialState 64)
      `shouldSatisfy` isLeft
