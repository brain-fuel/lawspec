// User-owned LawSpec adapter: a stack and a counter.
import * as data from '.././lawspec_data.js';

const counters = new Map<number, bigint>();
let ids = 0;

export function empty(value0: unknown): data.Stack {
  return new data.StackEmpty();
}

export function push(value0: number, value1: data.Stack): data.PushFlow {
  return new data.PushFlow(new data.StackPush(value0, value1));
}

// The flow signature guarantees a nonempty stack.
export function pop(value0: data.Stack): data.PopFlow {
  const cell = value0 as data.StackPush;
  return new data.PopFlow(cell.top, cell.rest);
}

export function peek(value0: data.Stack): data.PeekFlow {
  const cell = value0 as data.StackPush;
  return new data.PeekFlow(cell.top, cell);
}

export function newCounter(value0: unknown): data.Counter {
  const id = ids++;
  counters.set(id, 0n);
  return new data.Counter(id);
}

export async function increment(value0: data.Counter): Promise<bigint> {
  counters.set(value0.id, counters.get(value0.id)! + 1n);
  return counters.get(value0.id)!;
}

export async function decrement(value0: data.Counter): Promise<bigint> {
  counters.set(value0.id, counters.get(value0.id)! - 1n);
  return counters.get(value0.id)!;
}

export async function read(value0: data.Counter): Promise<bigint> {
  return counters.get(value0.id)!;
}
