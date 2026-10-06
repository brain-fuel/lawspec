# Application code: a Clock bound in lawspec.json in place of the default
# one. It keeps the default clock's readings.
import lawspec.time


class SteadyClock:
    def __init__(self):
        self.inner = lawspec.time.ClockHandler()
        self.readings = 0

    def now(self):
        self.readings += 1
        return self.inner.now()

    def sleep(self, value0):
        self.inner.sleep(value0)
