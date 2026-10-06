// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through LawSpecRuntime.Fail.
package example;

import lawspec.runtime.LawSpecRuntime;

public final class Shop {
  // (Int32 -> Int32)
  public static int refund(lawspec.abilities.example.Abilities.Gateway gateway, int value0) {
    if (value0 > 100000) throw new LawSpecRuntime.Fail(new lawspec.data.PaymentError.TooLarge());
    return gateway.capture(value0).cents();
  }

  /** The native handler of Journal: note. */
  public static final class JournalHandler implements lawspec.abilities.example.Shop.Journal {
    private final java.util.List<String> lines = new java.util.ArrayList<>();

    @Override
    public void note(java.lang.String value0) {
      lines.add(value0);
    }
  }

  /** The native handler of Store Int32: load, save. */
  public static final class StoreInt32Handler implements lawspec.abilities.example.Shop.StoreInt32 {
    private java.lang.Integer value = 0;

    @Override
    public java.lang.Integer load() {
      return value;
    }

    @Override
    public void save(java.lang.Integer value0) {
      value = value0;
    }
  }

  /** The native handler of Store Text: load, save. */
  public static final class StoreTextHandler implements lawspec.abilities.example.Shop.StoreText {
    private java.lang.String value = "";

    @Override
    public java.lang.String load() {
      return value;
    }

    @Override
    public void save(java.lang.String value0) {
      value = value0;
    }
  }

  /** The native handler of Meter: reading. */
  public static final class MeterHandler implements lawspec.abilities.example.Shop.Meter {
    @Override
    public java.lang.Integer reading() {
      return 3;
    }
  }
}
