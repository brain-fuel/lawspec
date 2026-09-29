// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function firstLine(value0) {
  return value0.value[0];
}

export function validateOrder(value0) {
  if (value0.id.length === 0) return new data.Left(new data.OrderErrorInvalidOrderId());
  if (!(value0.quantity >= 1 && value0.quantity <= 1000)) return new data.Left(new data.OrderErrorInvalidQuantity());
  return new data.Right(new data.ValidatedOrderValidatedOrder(
      new data.OrderIdOrderId(value0.id), new data.UnitQuantityUnitQuantity(value0.quantity)));
}

export function priceOrder(value0) {
  const total = BigInt(value0.quantity.value) * 25n;
  if (total > 20000n) return new data.Left(new data.OrderErrorPriceTooHigh());
  return new data.Right(new data.PricedOrderPricedOrder(value0.id, value0.quantity, total));
}

export function placeOrder(value0) {
  const validated = validateOrder(value0);
  if (validated instanceof data.Left) return validated;
  return priceOrder(validated.value);
}
