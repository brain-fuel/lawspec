// User-owned LawSpec adapter: a page-view counter. JavaScript runs one call
// at a time, so each hit is atomic; the counter is exact, and so also
// eventually consistent.
import * as data from '.././lawspec_data.js';

const counts = new Map<number, bigint>();
let ids = 0;

export function newViews(value0: unknown): data.Views {
  const identity = ids++;
  counts.set(identity, 0n);
  return new data.Views(identity);
}

export function hit(value0: data.Views): bigint {
  const after = counts.get(value0.id)! + 1n;
  counts.set(value0.id, after);
  return after;
}

export function total(value0: data.Views): bigint {
  return counts.get(value0.id)!;
}
