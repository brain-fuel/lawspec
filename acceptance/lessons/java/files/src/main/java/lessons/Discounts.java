// User-owned LawSpec adapter.
package lessons;

public final class Discounts {
  public static long applyDiscount(long value0, int value1) {
    return value0 * (100 - value1) / 100;
  }
}
