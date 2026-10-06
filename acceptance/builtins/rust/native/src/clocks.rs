// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
use crate::lawspec_abilities::lawspec_time::Clock;

pub struct SteadyClock {
    inner: crate::lawspec_time::ClockHandler,
    readings: std::sync::atomic::AtomicI64,
}

/// Makes the bound Clock.
pub fn steady_clock() -> SteadyClock {
    SteadyClock { inner: crate::lawspec_time::ClockHandler, readings: std::sync::atomic::AtomicI64::new(0) }
}

impl Clock for SteadyClock {
    fn now(&self) -> crate::lawspec_data::Instant {
        self.readings.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.inner.now()
    }

    fn sleep(&self, value0: std::time::Duration) -> () {
        self.inner.sleep(value0)
    }
}
