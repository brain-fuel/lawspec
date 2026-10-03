// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: lessons.checkout::type::RawOrder
// LawSpec result: Either (lessons.checkout::type::OrderProblem)
// (lessons.checkout::type::ValidOrder)
export function validate(
    value0: data.RawOrder
): data.Either<data.OrderProblem, data.ValidOrder> {
  throw new Error('validate');
}

// LawSpec argument 0: lessons.checkout::type::ValidOrder
// LawSpec result: lessons.checkout::type::Receipt
export function charge(value0: data.ValidOrder): data.Receipt {
  throw new Error('charge');
}
