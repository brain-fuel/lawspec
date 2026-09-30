// User-owned LawSpec adapter.
package lessons;

public final class Evidence {
  public static boolean isWeekend(byte value0) {
    return value0 == 0 || value0 == 6;
  }

  public static long roundToDollars(long value0) {
    return value0 - value0 % 100;
  }
}
