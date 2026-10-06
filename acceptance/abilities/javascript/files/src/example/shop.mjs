// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through the runtime's Fail.
import * as data from '.././lawspec_data.mjs';
import * as schema from '.././lawspec_schema.mjs';
import * as ls from '../lawspec_runtime.mjs';
// LawSpec argument 0: Int32
// LawSpec result: Int32
export function refund(gateway, value0) {
  if (value0 > 100000) throw new ls.Fail(new data.PaymentErrorTooLarge());
  return gateway.capture(value0).cents;
}

/** The native handler of Journal: note. */
export class JournalHandler {
  lines = [];
  note(value0) {
    this.lines.push(value0);
  }
}

/** The native handler of Store Int32: load, save. */
export class StoreInt32Handler {
  value = 0;
  load() {
    return this.value;
  }
  save(value0) {
    this.value = value0;
  }
}

/** The native handler of Store Text: load, save. */
export class StoreTextHandler {
  value = '';
  load() {
    return this.value;
  }
  save(value0) {
    this.value = value0;
  }
}

/** The native handler of Meter: reading. */
export class MeterHandler {
  reading() {
    return 3;
  }
}
