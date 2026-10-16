module PythonBindingNamesSpec (test_pythonBindingNames) where

import Data.List (isInfixOf, isPrefixOf, tails)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonExpr as Python
import LawSpec.Scalar (Scalar(..))

test_pythonBindingNames :: Spec
test_pythonBindingNames = describe "Python binding hygiene" $ do
  it "keeps an outer name free inside a generated lambda" $ do
    let output = emitted (binding "bound" (constant False) (local "_m0"))
    output `shouldSatisfy` isInfixOf "lambda _m1: (_m0)"
    output `shouldNotSatisfy` isInfixOf "lambda _m0:"
  it "keeps first-assigned names and allocator gaps across repeated finite-search binders" $ do
    let output = emitted (expression (C.If (local "_m0")
          (binding "repeated" (constant True) (local "repeated"))
          (binding "repeated" (constant False)
            (binding "nested" (constant True) (local "nested")))))
    length (filter (isPrefixOf "lambda _m1:") (tails output)) `shouldBe` 2
    output `shouldSatisfy` isInfixOf "lambda _m3: (_m3)"
    output `shouldSatisfy` isInfixOf "if _m0 else"
    output `shouldNotSatisfy` isInfixOf "lambda _m2:"
  where
    expression node = C.Expr (C.scalarType "Bool") node (C.GeneratedFrom (C.Id "binding-hygiene"))
    local name = expression (C.Local (C.Id name))
    constant value = expression (C.Constant (SBool value))
    binding name value body = expression (C.Let (C.Binder (C.Id name) name (C.scalarType "Bool")) value body)
    emitted = either error (D.render D.Compact) . Python.renderExpression [] 64 C.idText
      (\_ _ -> Left "unexpected external call in binding hygiene test")
