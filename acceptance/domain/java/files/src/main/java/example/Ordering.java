// User-owned LawSpec adapter.
package example;

import lawspec.data.NonEmptyList;
import lawspec.data.OrderError;
import lawspec.data.OrderId;
import lawspec.data.PricedOrder;
import lawspec.data.UnitQuantity;
import lawspec.data.UnvalidatedOrder;
import lawspec.data.ValidatedOrder;
import lawspec.runtime.LawSpecRuntime;

public final class Ordering {
  public static int firstLine(NonEmptyList<Integer> value0) {
    return value0.value().get(0);
  }

  public static LawSpecRuntime.Either<OrderError, ValidatedOrder> validateOrder(
      UnvalidatedOrder value0) {
    if (value0.id().isEmpty()) return new LawSpecRuntime.Left<>(new OrderError.InvalidOrderId());
    if (!(value0.quantity() >= 1 && value0.quantity() <= 1000)) {
      return new LawSpecRuntime.Left<>(new OrderError.InvalidQuantity());
    }
    return new LawSpecRuntime.Right<>(new ValidatedOrder(
        new OrderId(value0.id()), new UnitQuantity(value0.quantity())));
  }

  public static LawSpecRuntime.Either<OrderError, PricedOrder> priceOrder(ValidatedOrder value0) {
    long total = (long) value0.quantity().value() * 25;
    if (total > 20000) return new LawSpecRuntime.Left<>(new OrderError.PriceTooHigh());
    return new LawSpecRuntime.Right<>(new PricedOrder(value0.id(), value0.quantity(), total));
  }

  public static LawSpecRuntime.Either<OrderError, PricedOrder> placeOrder(UnvalidatedOrder value0) {
    return switch (validateOrder(value0)) {
      case LawSpecRuntime.Left<OrderError, ValidatedOrder> failure -> new LawSpecRuntime.Left<>(failure.value());
      case LawSpecRuntime.Right<OrderError, ValidatedOrder> order -> priceOrder(order.value());
    };
  }
}
