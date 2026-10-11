// User-owned LawSpec adapter.
module Lessons.Checkout

open LawSpec
open LawSpec.Data

let validate (value0: RawOrder) : Either<OrderProblem, ValidOrder> =
    if value0.Item = "" then Either.Left EmptyItem
    elif value0.Quantity < 1 || value0.Quantity > 20 then Either.Left BadQuantity
    else Either.Right { Item = value0.Item; Quantity = { Value = value0.Quantity } }

let charge (value0: ValidOrder) : Receipt =
    { Item = value0.Item; Total = int64 value0.Quantity.Value * 250L }
