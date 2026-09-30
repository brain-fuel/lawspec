// User-owned LawSpec adapter.
package lessons;

import lawspec.data.OrderProblem;
import lawspec.data.Quantity;
import lawspec.data.RawOrder;
import lawspec.data.Receipt;
import lawspec.data.ValidOrder;
import lawspec.runtime.LawSpecRuntime;

public final class Checkout {
  public static LawSpecRuntime.Either<OrderProblem, Receipt> checkout(RawOrder value0) {
    var validated = validate(value0);
    if (validated instanceof LawSpecRuntime.Left<OrderProblem, ValidOrder> problem) {
      return new LawSpecRuntime.Left<>(problem.value());
    }
    return new LawSpecRuntime.Right<>(charge(((LawSpecRuntime.Right<OrderProblem, ValidOrder>) validated).value()));
  }

  public static LawSpecRuntime.Either<OrderProblem, ValidOrder> validate(RawOrder value0) {
    var order = (RawOrder.RawOrderCase) value0;
    if (order.item.isEmpty()) return new LawSpecRuntime.Left<>(new OrderProblem.EmptyItemCase());
    if (order.quantity < 1 || order.quantity > 20) return new LawSpecRuntime.Left<>(new OrderProblem.BadQuantityCase());
    return new LawSpecRuntime.Right<>(new ValidOrder.ValidOrderCase(order.item, new Quantity.QuantityCase(order.quantity)));
  }

  public static Receipt charge(ValidOrder value0) {
    var order = (ValidOrder.ValidOrderCase) value0;
    long count = ((Quantity.QuantityCase) order.quantity).value;
    return new Receipt.ReceiptCase(order.item, count * 250);
  }
}
