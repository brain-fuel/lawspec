// User-owned LawSpec adapter.
module Lessons.Discounts

let applyDiscount (value0: int64) (value1: int) : int64 = value0 * int64 (100 - value1) / 100L
