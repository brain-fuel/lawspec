package till;

import lawspec.abilities.example.Till.Drawer;

/** Payments: a bound adapter. It gets its till as the generated interface. */
public final class Payments {
  private Payments() {}

  public static Cash pay(Drawer till, long cents) {
    if (cents < 0) throw new BadAmount("negative");
    if (cents > 1000) throw new CardDeclined();
    return new Cash(till.take(new lawspec.data.Money(cents)).cents());
  }
}
