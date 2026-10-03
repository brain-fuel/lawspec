// User-owned LawSpec adapter.
package lessons;

import lawspec.runtime.LawSpecRuntime;

public final class Checkout {
  // (lessons.checkout::type::RawOrder -> Either (lessons.checkout::type::OrderProblem)
  // (lessons.checkout::type::ValidOrder))
  public static LawSpecRuntime.Either<lawspec.data.OrderProblem, lawspec.data.ValidOrder>
      validate(lawspec.data.RawOrder value0) {
    throw new UnsupportedOperationException(
        "validate -> Either (lessons.checkout::type::OrderProblem) (lessons.checkout::type::ValidOrder)");
  }

  // (lessons.checkout::type::ValidOrder -> lessons.checkout::type::Receipt)
  public static lawspec.data.Receipt charge(lawspec.data.ValidOrder value0) {
    throw new UnsupportedOperationException("charge -> lessons.checkout::type::Receipt");
  }
}
