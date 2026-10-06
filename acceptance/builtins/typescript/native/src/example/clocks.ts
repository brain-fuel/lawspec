// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
import * as time from '../lawspec/time.js';
import * as data from '../lawspec_data.js';

export class SteadyClock {
  private inner = new time.ClockHandler();
  private readings = 0n;
  now(): data.Instant {
    this.readings += 1n;
    return this.inner.now();
  }
  sleep(value0: data.Duration): void {
    this.inner.sleep(value0);
  }
}
