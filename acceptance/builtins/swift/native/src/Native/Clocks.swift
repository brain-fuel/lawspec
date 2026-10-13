// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
import LawSpecRuntime

extension Example {
    enum Clocks {
        final class SteadyClock: LawSpec.Abilities.LawspecTime.Clock {
            let inner: any LawSpec.Abilities.LawspecTime.Clock = LawSpec.DefaultHandlers.clock()
            var readings: Int64 = 0

            func now() -> Instant {
                readings += 1
                return inner.now()
            }

            func sleep(_ value0: Duration) { inner.sleep(value0) }
        }
    }
}
