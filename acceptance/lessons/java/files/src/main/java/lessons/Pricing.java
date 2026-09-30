// User-owned LawSpec adapter.
package lessons;

public final class Pricing {
  public static long priceInCents(int value0) {
    long each = value0 >= 10 ? 225 : 250;
    return value0 * each;
  }
}
