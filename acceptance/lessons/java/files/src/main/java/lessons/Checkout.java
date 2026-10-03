// User-owned LawSpec adapter.
package lessons;

import lawspec.data.OrderProblem;
import lawspec.data.Quantity;
import lawspec.data.RawOrder;
import lawspec.data.Receipt;
import lawspec.data.ValidOrder;
import lawspec.runtime.LawSpecRuntime;

public final class Checkout {
  public static LawSpecRuntime.Either<OrderProblem, ValidOrder> validate(RawOrder value0) {
    if (value0.item().isEmpty()) return new LawSpecRuntime.Left<>(new OrderProblem.EmptyItem());
    if (value0.quantity() < 1 || value0.quantity() > 20) return new LawSpecRuntime.Left<>(new OrderProblem.BadQuantity());
    return new LawSpecRuntime.Right<>(new ValidOrder(value0.item(), new Quantity(value0.quantity())));
  }

  public static Receipt charge(ValidOrder value0) {
    return new Receipt(value0.item(), value0.quantity().value() * 250L);
  }
}
