module DomainModelSpec (spec) where

import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Compile
import LawSpec.Core.Evidence
import LawSpec.Frontend (compileCore)
import LawSpec.Model hiding (Expectation)

orders :: String
orders = unlines
  [ "unit example.orders"
  , "wrapper UnitQuantity is Int32 where value >= 1 && value <= 1000 end"
  , "wrapper OrderId is Text where prelude.length value > 0 end"
  , "wrapper NonEmptyList (a :: Type) is List a where prelude.length value > 0 end"
  , "type UnvalidatedOrder is UnvalidatedOrder id :: Text quantity :: Int32 end"
  , "type ValidatedOrder is ValidatedOrder id :: OrderId quantity :: UnitQuantity end"
  , "type PricedOrder is PricedOrder id :: OrderId quantity :: UnitQuantity total :: Int64 end"
  , "type OrderError is | InvalidOrderId | InvalidQuantity | PriceTooHigh end"
  , "type Receipt is Receipt order :: PricedOrder end"
  ]

compileOrders :: String -> Either [Diagnostic] ([Unit], [Expanded])
compileOrders extra = compile [Source "orders.lawspec" (orders ++ extra)]

rejects :: String -> String -> Expectation
rejects fragment extra = case compileOrders extra of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

placeOrder :: String
placeOrder = unlines
  [ "workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is"
  , "  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder"
  , "  priceOrder :: ValidatedOrder -> Either OrderError PricedOrder"
  , "end" ]

spec :: Spec
spec = describe "domain modeling" $ do
  describe "wrappers" $ do
    it "elaborate to a nominal type with a checked constructor and an unwrapping definition" $
      case compileOrders "" of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right (units, _) -> do
          let u = head units
              quantity = [d | d <- dataTypes u, dataTypeName d == "UnitQuantity"]
          map (map dataConstructorName . dataTypeConstructors) quantity `shouldBe` [["UnitQuantity"]]
          map (map (map fst . dataConstructorFields) . dataTypeConstructors) quantity `shouldBe` [[["value"]]]
          map functionName (functionDefinitions u) `shouldSatisfy` any (isInfixOf "valueOfUnitQuantity")
          [dataTypeParameters d | d <- dataTypes u, dataTypeName d == "NonEmptyList"] `shouldBe` [["a"]]
    it "accept valid construction in examples and reject invalid construction" $ do
      let law q = "law `q` is definition is `for all` (q :: UnitQuantity) . valueOfUnitQuantity q >= 1 = true end\n" ++
                  "example `e` is q = UnitQuantity " ++ q ++ " expect valueOfUnitQuantity q = " ++ q ++ " end end\n"
      compileOrders (law "1000") `shouldSatisfy` either (const False) (const True)
      rejects "field refinement failed" (law "0")
    it "record construction invariants as runtime-checked evidence" $
      case compileCore 64 defaultGeneration [Source "orders.lawspec" orders] of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right program -> do
          let construction = [o | o <- programEvidence program, obligationStage o == "construction"]
          length construction `shouldBe` 3
          map obligationStatus construction `shouldSatisfy` all (== RuntimeChecked)
    it "reject a wrapper that duplicates a data type" $
      rejects "duplicate data type: OrderError" "wrapper OrderError is Int32 end\n"

  describe "workflows" $ do
    it "declare the steps and add a railway composition law" $
      case compileOrders placeOrder of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right (units, expanded) -> do
          map fst (functions (head units)) `shouldSatisfy`
            (\names -> all (`elem` names) ["placeOrder", "validateOrder", "priceOrder"])
          map name expanded `shouldContain` ["placeOrder composes its steps"]
    it "compose total steps without Either" $
      compileOrders (unlines
        [ "workflow receipt :: PricedOrder -> Receipt is"
        , "  issue :: PricedOrder -> Receipt"
        , "end" ]) `shouldSatisfy` either (const False) (const True)
    it "compose total steps after fallible steps" $
      compileOrders (unlines
        [ "workflow checkout :: UnvalidatedOrder -> Either OrderError Receipt is"
        , "  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder"
        , "  priceOrder :: ValidatedOrder -> Either OrderError PricedOrder"
        , "  issue :: PricedOrder -> Receipt"
        , "end" ]) `shouldSatisfy` either (const False) (const True)
    it "share a step declared with the same type" $
      compileOrders (placeOrder ++ unlines
        [ "workflow validate :: UnvalidatedOrder -> Either OrderError ValidatedOrder is"
        , "  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder"
        , "end" ]) `shouldSatisfy` either (const False) (const True)

    describe "diagnostics" $ do
      it "reject a step that receives the wrong state" $
        rejects "step priceOrder expects UnvalidatedOrder but receives ValidatedOrder" (unlines
          [ "workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is"
          , "  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder"
          , "  priceOrder :: UnvalidatedOrder -> Either OrderError PricedOrder"
          , "end" ])
      it "reject steps with different error types" $
        rejects "fails with Text but earlier steps fail with" (unlines
          [ "workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is"
          , "  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder"
          , "  priceOrder :: ValidatedOrder -> Either Text PricedOrder"
          , "end" ])
      it "reject a workflow whose result differs from its steps" $
        rejects "but the workflow returns" (unlines
          [ "workflow placeOrder :: UnvalidatedOrder -> PricedOrder is"
          , "  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder"
          , "  priceOrder :: ValidatedOrder -> Either OrderError PricedOrder"
          , "end" ])
      it "reject steps with more than one input" $
        rejects "must take exactly one input" (unlines
          [ "workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is"
          , "  validateOrder :: UnvalidatedOrder -> Int32 -> Either OrderError ValidatedOrder"
          , "end" ])
      it "reject a step redeclared with a different type" $
        rejects "declared with two different types" (placeOrder ++ unlines
          [ "workflow other :: UnvalidatedOrder -> ValidatedOrder is"
          , "  validateOrder :: UnvalidatedOrder -> ValidatedOrder"
          , "end" ])
