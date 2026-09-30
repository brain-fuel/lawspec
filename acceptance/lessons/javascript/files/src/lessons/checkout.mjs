// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function checkout(value0) {
  const validated = validate(value0);
  if (validated instanceof data.Left) return validated;
  return new data.Right(charge(validated.value));
}

export function validate(value0) {
  if (value0.item.length === 0) return new data.Left(new data.OrderProblemEmptyItem());
  if (value0.quantity < 1 || value0.quantity > 20) return new data.Left(new data.OrderProblemBadQuantity());
  return new data.Right(new data.ValidOrderValidOrder(value0.item, new data.QuantityQuantity(value0.quantity)));
}

export function charge(value0) {
  return new data.ReceiptReceipt(value0.item, BigInt(value0.quantity.value) * 250n);
}
