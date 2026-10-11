// User-owned LawSpec adapter.
module Lessons.Menu

open LawSpec.Data

let priceOf (value0: Item) : int64 =
    match value0 with
    | Espresso -> 250L
    | Latte -> 350L
    | Tea -> 300L

let cheapest (value0: int64) (value1: int64) : int64 = min value0 value1
