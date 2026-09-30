// User-owned LawSpec adapter.
package lessons;

import lawspec.data.Item;

public final class Menu {
  public static long priceOf(Item value0) {
    if (value0 instanceof Item.EspressoCase) return 250;
    if (value0 instanceof Item.LatteCase) return 350;
    return 300;
  }

  public static long cheapest(long value0, long value1) {
    return Math.min(value0, value1);
  }
}
