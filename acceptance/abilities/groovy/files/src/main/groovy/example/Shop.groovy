// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through LawSpecRuntime.Fail.
package example

import lawspec.runtime.LawSpecRuntime

@groovy.transform.CompileStatic
final class Shop {
  // (Int32 -> Int32)
  static int refund(lawspec.abilities.example.Abilities.Gateway gateway, int value0) {
    if (value0 > 100000) throw new LawSpecRuntime.Fail(new lawspec.data.PaymentError.TooLarge())
    return gateway.capture(value0).cents()
  }

  /** The native handler of Log: note. */
  static final class LogHandler implements lawspec.abilities.example.Shop.Log {
    private final java.util.List<String> lines = new java.util.ArrayList<>()

    @Override
    void note(String value0) {
      lines.add(value0)
    }
  }

  /** The native handler of Store Int32: load, save. */
  static final class StoreInt32Handler implements lawspec.abilities.example.Shop.StoreInt32 {
    private Integer value = 0

    @Override
    Integer load() {
      return value
    }

    @Override
    void save(Integer value0) {
      value = value0
    }
  }

  /** The native handler of Store Text: load, save. */
  static final class StoreTextHandler implements lawspec.abilities.example.Shop.StoreText {
    private String value = ''

    @Override
    String load() {
      return value
    }

    @Override
    void save(String value0) {
      value = value0
    }
  }

  /** The native handler of Meter: reading. */
  static final class MeterHandler implements lawspec.abilities.example.Shop.Meter {
    @Override
    Integer reading() {
      return 3
    }
  }
}
