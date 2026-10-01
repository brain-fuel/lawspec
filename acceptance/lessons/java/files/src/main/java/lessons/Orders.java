// User-owned LawSpec adapter.
package lessons;

import lawspec.data.Drink;
import lawspec.data.Size;

public final class Orders {
  public static long price(Drink value0) {
    long base = switch (value0.size()) {
      case Size.Small small -> 250;
      case Size.Large large -> 320;
    };
    return base + value0.shots() * 60L;
  }
}
