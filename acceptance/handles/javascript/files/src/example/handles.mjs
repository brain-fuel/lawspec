// User-owned LawSpec adapter: Jobs is a plain array used as a queue.
// JavaScript runs one call at a time, so the array needs no lock.
import * as data from '.././lawspec_data.mjs';

export function newJobs(value0) {
  return [];
}

export function submit(value0, value1) {
  value0.push(value1);
}

export function take(value0) {
  return value0.length === 0 ? new data.Nothing() : new data.Just(value0.shift());
}

export function pending(value0) {
  return value0.length;
}
