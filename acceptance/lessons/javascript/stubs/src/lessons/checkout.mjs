// User-owned LawSpec adapter.
// LawSpec argument rawOrder1: lessons.checkout::type::RawOrder
// LawSpec result: Either (lessons.checkout::type::OrderProblem)
// (lessons.checkout::type::ValidOrder)
export function validate(rawOrder1)
{
  throw new Error('validate');
}

// LawSpec argument validOrder1: lessons.checkout::type::ValidOrder
// LawSpec result: lessons.checkout::type::Receipt
export function charge(validOrder1)
{
  throw new Error('charge');
}
