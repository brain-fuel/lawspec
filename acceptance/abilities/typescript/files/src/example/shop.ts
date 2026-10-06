// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through the runtime's Fail.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import type * as abilities from '.././lawspec_abilities/example/shop.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: Int32
// LawSpec result: Int32
export function refund(
    gateway: import('.././lawspec_abilities/example/abilities.js').Gateway,
    value0: number
): number {
  if (value0 > 100000) throw new ls.Fail(new data.PaymentErrorTooLarge());
  return gateway.capture(value0).cents;
}

/** The native handler of Journal: note. */
export class JournalHandler implements abilities.Journal {
  lines: string[] = [];
  note(value0: string): void {
    this.lines.push(value0);
  }
}

/** The native handler of Store Int32: load, save. */
export class StoreInt32Handler implements abilities.StoreInt32 {
  value = 0;
  load(): number {
    return this.value;
  }
  save(value0: number): void {
    this.value = value0;
  }
}

/** The native handler of Store Text: load, save. */
export class StoreTextHandler implements abilities.StoreText {
  value = '';
  load(): string {
    return this.value;
  }
  save(value0: string): void {
    this.value = value0;
  }
}

/** The native handler of Meter: reading. */
export class MeterHandler implements abilities.Meter {
  reading(): number {
    return 3;
  }
}
