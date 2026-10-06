// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';
import * as schema from '.././lawspec_schema.mjs';
import * as ls from '../lawspec_runtime.mjs';
// LawSpec argument 0: example.harness::type::Order
// LawSpec result: Int32
export function discount(value0) {
  // Ten percent off orders of more than ten items.
  return value0.items > 10 ? Math.floor(value0.total / 10) : 0;
}

// LawSpec argument 0: Int32
// LawSpec result: Int32
export function roundCents(value0) {
  // To the nearest ten cents, halves down: known to break a law.
  return Math.floor((value0 + 4) / 10) * 10;
}

// LawSpec argument 0: Int32
// LawSpec result: Bool
export function book(ledger, value0) {
  return ledger.accept(value0);
}

/** The native handler of Ledger: accept. */
export class LedgerHandler {
  accept(value0) {
    return value0 > 0;
  }
}
