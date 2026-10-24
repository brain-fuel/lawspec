// User-owned LawSpec adapter.
// LawSpec argument 0: lessons.checkout::type::RawOrder
// LawSpec result: Either (lessons.checkout::type::OrderProblem)
// (lessons.checkout::type::ValidOrder)
export function validate(value0) {
  throw new Error("validate");
}

// LawSpec argument 0: lessons.checkout::type::ValidOrder
// LawSpec result: lessons.checkout::type::Receipt
export function charge(value0) {
  throw new Error("charge");
}
