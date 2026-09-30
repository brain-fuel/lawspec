// User-owned LawSpec adapter.
package lessons;

public final class Codec {
  public static String formatQuantity(int value0) {
    return Integer.toString(value0);
  }

  public static int parseQuantity(String value0) {
    return Integer.parseInt(value0);
  }
}
