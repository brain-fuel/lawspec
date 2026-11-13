// User-owned LawSpec adapter. Implement these functions.
module Lessons.Checkout

/// (lessons.checkout::type::RawOrder -> Either (lessons.checkout::type::OrderProblem) (lessons.checkout::type::ValidOrder))
let validate (rawOrder1: LawSpec.Data.RawOrder) : LawSpec.Either<LawSpec.Data.OrderProblem, LawSpec.Data.ValidOrder> =
    failwith "not implemented: lessons.checkout::validate"

/// (lessons.checkout::type::ValidOrder -> lessons.checkout::type::Receipt)
let charge (validOrder1: LawSpec.Data.ValidOrder) : LawSpec.Data.Receipt =
    failwith "not implemented: lessons.checkout::charge"
