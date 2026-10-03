// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function firstLine(value0) {
  return value0.value[0];
}

export function validateOrder(value0) {
  if (value0.id.length === 0) return new data.Left(new data.OrderErrorInvalidOrderId());
  if (!(value0.quantity >= 1 && value0.quantity <= 1000)) return new data.Left(new data.OrderErrorInvalidQuantity());
  return new data.Right(new data.ValidatedOrder(
      new data.OrderId(value0.id), new data.UnitQuantity(value0.quantity)));
}

export function priceOrder(value0) {
  const total = BigInt(value0.quantity.value) * 25n;
  if (total > 20000n) return new data.Left(new data.OrderErrorPriceTooHigh());
  return new data.Right(new data.PricedOrder(value0.id, value0.quantity, total));
}

