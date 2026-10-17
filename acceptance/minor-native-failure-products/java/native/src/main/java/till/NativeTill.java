package till;

/** A till that keeps what it takes: the production handler, in the application's types. */
public final class NativeTill {
  private long taken;

  public Cash take(Cash money) {
    taken += money.cents();
    return new Cash(money.cents());
  }

  public Cash opening() {
    return new Cash(0);
  }
}
