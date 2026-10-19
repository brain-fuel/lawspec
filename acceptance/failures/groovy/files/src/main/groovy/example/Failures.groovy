// User-owned LawSpec adapter: the native Gateway handler.
package example

@groovy.transform.CompileStatic
final class Failures {
  // Native adapters that fail: they throw the runtime's Fail with a
  // PaymentError, which a law expects with `fails with`.
  static int refund(int value0) {
    if (value0 > 5000) throw new lawspec.runtime.LawSpecRuntime.Fail(new lawspec.data.PaymentError.TooLarge(5000))
    return value0
  }

  static java.util.concurrent.CompletableFuture<Integer> settle(int value0) {
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> {
      if (value0 < 0) throw new lawspec.runtime.LawSpecRuntime.Fail(new lawspec.data.PaymentError.Blocked())
      if (value0 == 0) throw new lawspec.runtime.LawSpecRuntime.Fail(new lawspec.data.PaymentError.Declined(new lawspec.data.Recordf5f10555f6c6efcfede6a1b5b3a543dda5cd98cceb0297c257aa71c41066c7c7('there is nothing to settle')))
      return value0
    })
  }

  /** The native handler of Gateway: decide. */
  static final class GatewayHandler implements lawspec.abilities.example.Failures.Gateway {
    @Override
    lawspec.data.Decision decide(Integer value0) {
      if (value0 < 0) return new lawspec.data.Decision.Block()
      if (value0 % 2 == 1) return new lawspec.data.Decision.Decline('an odd amount')
      return new lawspec.data.Decision.Approve()
    }
  }
}
