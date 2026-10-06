// User-owned LawSpec adapter: the native Gateway handler.
package example;

public final class Failures {
  // Native adapters that fail: they throw the runtime's Fail with a
  // PaymentError, which a law expects with `fails with`.
  public static int refund(int value0) {
    if (value0 > 5000) throw new lawspec.runtime.LawSpecRuntime.Fail(new lawspec.data.PaymentError.TooLarge(5000));
    return value0;
  }

  public static java.util.concurrent.CompletableFuture<java.lang.Integer> settle(int value0) {
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> {
      if (value0 < 0) throw new lawspec.runtime.LawSpecRuntime.Fail(new lawspec.data.PaymentError.Blocked());
      if (value0 == 0) throw new lawspec.runtime.LawSpecRuntime.Fail(new lawspec.data.PaymentError.Declined("there is nothing to settle"));
      return value0;
    });
  }

  /** The native handler of Gateway: decide. */
  public static final class GatewayHandler implements lawspec.abilities.example.Failures.Gateway {
    @Override
    public lawspec.data.Decision decide(java.lang.Integer value0) {
      if (value0 < 0) return new lawspec.data.Decision.Block();
      if (value0 % 2 == 1) return new lawspec.data.Decision.Decline("an odd amount");
      return new lawspec.data.Decision.Approve();
    }
  }
}
