// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Ordering

open LawSpec
open LawSpec.Data

let firstLine (lines: NonEmptyList<int>) : int = List.head lines.Value

let validateOrder (order: UnvalidatedOrder) : Either<OrderError, ValidatedOrder> =
    if order.Id = "" then Either.Left InvalidOrderId
    elif order.Quantity < 1 || order.Quantity > 1000 then Either.Left InvalidQuantity
    else Either.Right { Id = { OrderId.Value = order.Id }; Quantity = { UnitQuantity.Value = order.Quantity } }

let priceOrder (order: ValidatedOrder) : Either<OrderError, PricedOrder> =
    let total = int64 order.Quantity.Value * 25L
    if total > 20000L then Either.Left PriceTooHigh
    else Either.Right { PricedOrder.Id = order.Id; Quantity = order.Quantity; Total = total }
