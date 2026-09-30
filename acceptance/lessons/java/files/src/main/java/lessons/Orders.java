// User-owned LawSpec adapter.
package lessons;

import lawspec.data.Drink;
import lawspec.data.Size;

public final class Orders {
  public static long price(Drink value0) {
    var drink = (Drink.DrinkCase) value0;
    long base = drink.size instanceof Size.LargeCase ? 320 : 250;
    return base + drink.shots * 60L;
  }
}
