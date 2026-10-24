// Application code: a Clock bound in lawspec.edn in place of the default
// one. It keeps the default clock's readings.
package example

class SteadyClock extends lawspec.abilities.lawspec.Time.Clock {
  private val inner: lawspec.abilities.lawspec.Time.Clock = lawspec.Time.ClockHandler()
  private var readings = 0L

  override def now(): lawspec.data.Instant = synchronized {
    readings += 1
    inner.now()
  }

  override def sleep(value0: scala.concurrent.duration.FiniteDuration): scala.Unit = inner.sleep(value0)
}
