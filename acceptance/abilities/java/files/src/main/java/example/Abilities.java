// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
package example;

public final class Abilities {
  // (Int32 -> Bool)
  public static boolean charge(lawspec.abilities.example.Abilities.Gateway gateway, int value0) {
    if (gateway.authorize(value0) instanceof lawspec.data.Payment.Approved approved) {
      return gateway.capture(approved.cents()).cents() == value0;
    }
    return false;
  }

  /** The native handler of Gateway: authorize, capture, fee. */
  public static final class GatewayHandler implements lawspec.abilities.example.Abilities.Gateway {
    @Override
    public lawspec.data.Payment authorize(java.lang.Integer value0) {
      if (value0 < 0) return new lawspec.data.Payment.Declined();
      return new lawspec.data.Payment.Approved(value0);
    }

    @Override
    public lawspec.data.Receipt capture(java.lang.Integer value0) {
      return new lawspec.data.Receipt(value0);
    }

    @Override
    public java.lang.Integer fee() {
      return 25;
    }
  }
}
