// User-owned LawSpec adapter.
module Lessons.Evidence

let isWeekend (value0: sbyte) : bool = value0 = 0y || value0 = 6y

/// Truncate toward zero: the remainder has the dividend's sign, so the most
/// negative Int64 cannot overflow.
let roundToDollars (value0: int64) : int64 = value0 - value0 % 100L
