// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function firstLine(value0: data.NonEmptyList<number>): number {
  return value0.value[0];
}

export function validateOrder(value0: data.UnvalidatedOrder): data.Either<data.OrderError, data.ValidatedOrder> {
  if (value0.id.length === 0) return new data.Left(new data.OrderErrorInvalidOrderId());
  if (!(value0.quantity >= 1 && value0.quantity <= 1000)) return new data.Left(new data.OrderErrorInvalidQuantity());
  return new data.Right(new data.ValidatedOrder(
      new data.OrderId(value0.id), new data.UnitQuantity(value0.quantity)));
}

export function priceOrder(value0: data.ValidatedOrder): data.Either<data.OrderError, data.PricedOrder> {
  const total = BigInt(value0.quantity.value) * 25n;
  if (total > 20000n) return new data.Left(new data.OrderErrorPriceTooHigh());
  return new data.Right(new data.PricedOrder(value0.id, value0.quantity, total));
}

export function placeOrder(value0: data.UnvalidatedOrder): data.Either<data.OrderError, data.PricedOrder> {
  const validated = validateOrder(value0);
  if (validated instanceof data.Left) return validated as data.Either<data.OrderError, data.PricedOrder>;
  return priceOrder(validated.value);
}
