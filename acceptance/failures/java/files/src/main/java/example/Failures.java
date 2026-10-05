// User-owned LawSpec adapter: the native Gateway handler.
package example;

public final class Failures {
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
