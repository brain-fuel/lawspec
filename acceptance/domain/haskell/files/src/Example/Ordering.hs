-- User-owned LawSpec adapter.
module Example.Ordering (firstLine, validateOrder, priceOrder) where

import qualified Data.Int as I
import qualified Data.Text as T
import qualified LawSpecData as Data

firstLine :: Data.NonEmptyList I.Int32 -> I.Int32
firstLine (Data.NonEmptyList values) = head values

validateOrder :: Data.UnvalidatedOrder -> Either Data.OrderError Data.ValidatedOrder
validateOrder (Data.UnvalidatedOrder orderId quantity)
  | T.null orderId = Left Data.OrderErrorInvalidOrderId
  | quantity < 1 || quantity > 1000 = Left Data.OrderErrorInvalidQuantity
  | otherwise = Right (Data.ValidatedOrder
      (Data.OrderId orderId) (Data.UnitQuantity quantity))

priceOrder :: Data.ValidatedOrder -> Either Data.OrderError Data.PricedOrder
priceOrder (Data.ValidatedOrder orderId quantity@(Data.UnitQuantity count))
  | total > 20000 = Left Data.OrderErrorPriceTooHigh
  | otherwise = Right (Data.PricedOrder orderId quantity total)
  where total = fromIntegral count * 25 :: I.Int64
