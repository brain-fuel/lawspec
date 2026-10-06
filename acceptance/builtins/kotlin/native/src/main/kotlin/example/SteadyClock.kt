// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
package example

class SteadyClock : lawspec.abilities.lawspec.Time.Clock {
    private val inner: lawspec.abilities.lawspec.Time.Clock = lawspec.Time.ClockHandler()
    private var readings = 0L

    override fun now(): lawspec.data.Instant {
        readings++
        return inner.now()
    }

    override fun sleep(value0: kotlin.time.Duration) {
        inner.sleep(value0)
    }
}
