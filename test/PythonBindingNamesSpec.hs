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
    -- The binder's source name is taken by a free name, so it gets _2.
    let output = emitted (expression (C.Let (C.Binder (C.Id "bound") "outer" (C.scalarType "Bool")) (constant False)
          (expression (C.ShortCircuit C.And (local "outer") (local "bound")))))
    output `shouldSatisfy` isInfixOf "lambda outer_2: outer and outer_2"
    output `shouldNotSatisfy` isInfixOf "lambda outer:"
  it "keeps first-assigned names across repeated finite-search binders" $ do
    let output = emitted (expression (C.If (local "flag")
          (binding "repeated" (constant True) (local "repeated"))
          (binding "repeated" (constant False)
            (binding "nested" (constant True) (local "nested")))))
    length (filter (isPrefixOf "lambda repeated:") (tails output)) `shouldBe` 2
    output `shouldSatisfy` isInfixOf "lambda nested: nested"
    output `shouldSatisfy` isInfixOf "if flag else"
  where
    expression node = C.Expr (C.scalarType "Bool") node (C.GeneratedFrom (C.Id "binding-hygiene"))
    local name = expression (C.Local (C.Id name))
    constant value = expression (C.Constant (SBool value))
    binding name value body = expression (C.Let (C.Binder (C.Id name) name (C.scalarType "Bool")) value body)
    emitted = either error (D.render D.Compact) . Python.renderExpression [] 64 C.idText
      (\_ _ -> Left "unexpected external call in binding hygiene test")
