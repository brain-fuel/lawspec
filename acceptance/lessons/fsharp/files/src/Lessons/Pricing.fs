// User-owned LawSpec adapter.
module Lessons.Pricing

let priceInCents (value0: int) : int64 = int64 value0 * (if value0 >= 10 then 225L else 250L)
