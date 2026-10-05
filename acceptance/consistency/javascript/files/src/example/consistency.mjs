// User-owned LawSpec adapter: a page-view counter. JavaScript runs one call
// at a time, so each hit is atomic; the counter is exact, and so also
// eventually consistent.
import * as data from '.././lawspec_data.mjs';

const counts = new Map();
let ids = 0;

export function newViews(value0) {
  const identity = ids++;
  counts.set(identity, 0n);
  return new data.Views(identity);
}

export function hit(value0) {
  const after = counts.get(value0.id) + 1n;
  counts.set(value0.id, after);
  return after;
}

export function total(value0) {
  return counts.get(value0.id);
}
