// User-owned LawSpec adapter: a stack and a counter.
import * as data from '.././lawspec_data.mjs';

const counters = new Map();
let ids = 0;

export function empty(value0) {
  return new data.StackEmpty();
}

export function push(value0, value1) {
  return new data.PushFlow(new data.StackPush(value0, value1));
}

export function pop(value0) {
  return new data.PopFlow(value0.top, value0.rest);
}

export function peek(value0) {
  return new data.PeekFlow(value0.top, value0);
}

export function newCounter(value0) {
  const id = ids++;
  counters.set(id, 0n);
  return new data.Counter(id);
}

export async function increment(value0) {
  counters.set(value0.id, counters.get(value0.id) + 1n);
  return counters.get(value0.id);
}

export async function decrement(value0) {
  counters.set(value0.id, counters.get(value0.id) - 1n);
  return counters.get(value0.id);
}

export async function read(value0) {
  return counters.get(value0.id);
}
