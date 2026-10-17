package till

/** A till that keeps what it takes: the production handler, in the application's types. */
@groovy.transform.CompileStatic
final class NativeTill {
  private long taken

  Cash take(Cash money) {
    taken += money.cents()
    return new Cash(money.cents())
  }

  Cash opening() {
    return new Cash(0)
  }
}
