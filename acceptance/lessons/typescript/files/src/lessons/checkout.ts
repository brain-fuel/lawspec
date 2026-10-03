// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function validate(value0: data.RawOrder): data.Either<data.OrderProblem, data.ValidOrder> {
  if (value0.item.length === 0) return new data.Left(new data.OrderProblemEmptyItem());
  if (value0.quantity < 1 || value0.quantity > 20) return new data.Left(new data.OrderProblemBadQuantity());
  return new data.Right(new data.ValidOrder(value0.item, new data.Quantity(value0.quantity)));
}

export function charge(value0: data.ValidOrder): data.Receipt {
  return new data.Receipt(value0.item, BigInt(value0.quantity.value) * 250n);
}
