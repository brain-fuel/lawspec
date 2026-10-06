// User-owned LawSpec adapter.
package example;

public final class Harness {
  // (example.harness::type::Order -> Int32)
  public static int discount(lawspec.data.Order value0) {
    // Ten percent off orders of more than ten items.
    return value0.items() > 10 ? value0.total() / 10 : 0;
  }

  // (Int32 -> Int32)
  public static int roundCents(int value0) {
    // To the nearest ten cents, halves down: known to break a law.
    return (value0 + 4) / 10 * 10;
  }

  // (Int32 -> Bool)
  public static boolean book(lawspec.abilities.example.Harness.Ledger ledger, int value0) {
    return ledger.accept(value0);
  }

  /** The native handler of Ledger: accept. */
  public static final class LedgerHandler implements lawspec.abilities.example.Harness.Ledger {
    @Override
    public java.lang.Boolean accept(java.lang.Integer value0) {
      return value0 > 0;
    }
  }
}
