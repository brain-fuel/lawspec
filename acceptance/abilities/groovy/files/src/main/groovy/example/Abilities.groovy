// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
package example

@groovy.transform.CompileStatic
final class Abilities {
  // (Int32 -> Bool)
  static boolean charge(lawspec.abilities.example.Abilities.Gateway gateway, int value0) {
    if (gateway.authorize(value0) instanceof lawspec.data.Payment.Approved approved) {
      return gateway.capture(approved.value()).cents() == value0
    }
    return false
  }

  /** The native handler of Gateway: authorize, capture, fee. */
  static final class GatewayHandler implements lawspec.abilities.example.Abilities.Gateway {
    @Override
    lawspec.data.Payment authorize(Integer value0) {
      if (value0 < 0) return new lawspec.data.Payment.Declined()
      return new lawspec.data.Payment.Approved(value0)
    }

    @Override
    lawspec.data.Receipt capture(Integer value0) {
      return new lawspec.data.Receipt(value0)
    }

    @Override
    Integer fee() {
      return 25
    }
  }
}
