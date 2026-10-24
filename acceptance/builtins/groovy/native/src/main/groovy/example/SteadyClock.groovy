// Application code: a Clock bound in lawspec.edn in place of the default
// one. It keeps the default clock's readings.
package example

@groovy.transform.CompileStatic
final class SteadyClock implements lawspec.abilities.lawspec.Time.Clock {
  private final lawspec.abilities.lawspec.Time.Clock inner = new lawspec.Time.ClockHandler()
  private long readings

  @Override
  lawspec.data.Instant now() {
    readings++
    return inner.now()
  }

  @Override
  void sleep(java.time.Duration value0) {
    inner.sleep(value0)
  }
}
