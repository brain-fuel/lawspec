// User-owned LawSpec adapter.

package lessons;

import lawspec.runtime.LawSpecRuntime;

public final class Checkout
{
  // validate :: (lessons.checkout::type::RawOrder -> Either (lessons.checkout::type::OrderProblem)
  // (lessons.checkout::type::ValidOrder)) — 06-domain.lawspec:16
  public static LawSpecRuntime.Either<lawspec.data.OrderProblem, lawspec.data.ValidOrder>
      validate(lawspec.data.RawOrder value0)
  {
    throw new UnsupportedOperationException(
        "validate -> Either (lessons.checkout::type::OrderProblem) (lessons.checkout::type::ValidOrder)");
  }

  // charge :: (lessons.checkout::type::ValidOrder -> lessons.checkout::type::Receipt) —
  // 06-domain.lawspec:17
  public static lawspec.data.Receipt charge(lawspec.data.ValidOrder value0)
  {
    throw new UnsupportedOperationException("charge -> lessons.checkout::type::Receipt");
  }
}
