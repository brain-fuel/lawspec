// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
package example;

public final class SteadyClock implements lawspec.abilities.lawspec.Time.Clock {
  private final lawspec.abilities.lawspec.Time.Clock inner = new lawspec.Time.ClockHandler();
  private long readings;

  @Override
  public lawspec.data.Instant now() {
    readings++;
    return inner.now();
  }

  @Override
  public void sleep(java.time.Duration value0) {
    inner.sleep(value0);
  }
}
