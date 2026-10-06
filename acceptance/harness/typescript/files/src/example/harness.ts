// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import type * as abilities from '.././lawspec_abilities/example/harness.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: example.harness::type::Order
// LawSpec result: Int32
export function discount(value0: data.Order): number {
  // Ten percent off orders of more than ten items.
  return value0.items > 10 ? Math.floor(value0.total / 10) : 0;
}

// LawSpec argument 0: Int32
// LawSpec result: Int32
export function roundCents(value0: number): number {
  // To the nearest ten cents, halves down: known to break a law.
  return Math.floor((value0 + 4) / 10) * 10;
}

// LawSpec argument 0: Int32
// LawSpec result: Bool
export function book(ledger: abilities.Ledger, value0: number): boolean {
  return ledger.accept(value0);
}

/** The native handler of Ledger: accept. */
export class LedgerHandler implements abilities.Ledger {
  accept(value0: number): boolean {
    return value0 > 0;
  }
}
