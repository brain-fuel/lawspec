// User-owned LawSpec adapter.
package lessons;

import lawspec.data.Item;

public final class Menu {
  public static long priceOf(Item value0) {
    return switch (value0) {
      case Item.Espresso espresso -> 250;
      case Item.Latte latte -> 350;
      case Item.Tea tea -> 300;
    };
  }

  public static long cheapest(long value0, long value1) {
    return Math.min(value0, value1);
  }
}
