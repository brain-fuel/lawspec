// User-owned LawSpec adapters for the tables example.
package example;

public final class Tables {
  // (Int32 -> (Int32 -> Int32))
  public static int shippingCost(int value0, int value1) {
    return value0 * value1 + 5 * value0;
  }

  // (Int32 -> Text)
  public static String label(int value0) {
    return "parcel " + value0;
  }
}
