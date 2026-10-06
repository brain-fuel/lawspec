// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
import * as time from '../lawspec/time.mjs';
import * as data from '../lawspec_data.mjs';

export class SteadyClock {
  inner = new time.ClockHandler();
  readings = 0n;
  now() {
    this.readings += 1n;
    return this.inner.now();
  }
  sleep(value0) {
    this.inner.sleep(value0);
  }
}
