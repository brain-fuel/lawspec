-- User-owned LawSpec adapter.
module Example.Ordering (firstLine, validateOrder, priceOrder, placeOrder) where

import qualified Data.Int as I
import qualified Data.Text as T
import qualified LawSpecData as Data

firstLine :: Data.NonEmptyList I.Int32 -> I.Int32
firstLine (Data.NonEmptyListNonEmptyList values) = head values

validateOrder :: Data.UnvalidatedOrder -> Either Data.OrderError Data.ValidatedOrder
validateOrder (Data.UnvalidatedOrderUnvalidatedOrder orderId quantity)
  | T.null orderId = Left Data.OrderErrorInvalidOrderId
  | quantity < 1 || quantity > 1000 = Left Data.OrderErrorInvalidQuantity
  | otherwise = Right (Data.ValidatedOrderValidatedOrder
      (Data.OrderIdOrderId orderId) (Data.UnitQuantityUnitQuantity quantity))

priceOrder :: Data.ValidatedOrder -> Either Data.OrderError Data.PricedOrder
priceOrder (Data.ValidatedOrderValidatedOrder orderId quantity@(Data.UnitQuantityUnitQuantity count))
  | total > 20000 = Left Data.OrderErrorPriceTooHigh
  | otherwise = Right (Data.PricedOrderPricedOrder orderId quantity total)
  where total = fromIntegral count * 25 :: I.Int64

placeOrder :: Data.UnvalidatedOrder -> Either Data.OrderError Data.PricedOrder
placeOrder input = case validateOrder input of
  Left failure -> Left failure
  Right order -> priceOrder order
