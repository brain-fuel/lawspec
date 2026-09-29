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
    return ((NonEmptyList.NonEmptyListCase<Integer>) value0).value.get(0);
  }

  public static LawSpecRuntime.Either<OrderError, ValidatedOrder> validateOrder(
      UnvalidatedOrder value0) {
    var input = (UnvalidatedOrder.UnvalidatedOrderCase) value0;
    if (input.id.isEmpty()) return new LawSpecRuntime.Left<>(new OrderError.InvalidOrderIdCase());
    if (!(input.quantity >= 1 && input.quantity <= 1000)) {
      return new LawSpecRuntime.Left<>(new OrderError.InvalidQuantityCase());
    }
    return new LawSpecRuntime.Right<>(new ValidatedOrder.ValidatedOrderCase(
        new OrderId.OrderIdCase(input.id), new UnitQuantity.UnitQuantityCase(input.quantity)));
  }

  public static LawSpecRuntime.Either<OrderError, PricedOrder> priceOrder(ValidatedOrder value0) {
    var order = (ValidatedOrder.ValidatedOrderCase) value0;
    long total = (long) ((UnitQuantity.UnitQuantityCase) order.quantity).value * 25;
    if (total > 20000) return new LawSpecRuntime.Left<>(new OrderError.PriceTooHighCase());
    return new LawSpecRuntime.Right<>(new PricedOrder.PricedOrderCase(order.id, order.quantity, total));
  }

  public static LawSpecRuntime.Either<OrderError, PricedOrder> placeOrder(UnvalidatedOrder value0) {
    var validated = validateOrder(value0);
    if (validated instanceof LawSpecRuntime.Left<OrderError, ValidatedOrder> failure) {
      return new LawSpecRuntime.Left<>(failure.value());
    }
    return priceOrder(((LawSpecRuntime.Right<OrderError, ValidatedOrder>) validated).value());
  }
}
