// User-owned LawSpec adapter: a queue, a set and a map shared between
// tasks. JavaScript runs one task at a time, so each structure is atomic as
// long as no call awaits between reading and writing it.
import * as data from '.././lawspec_data.js';

let ids = 0;
const queues = new Map<number, number[]>();
const sets = new Map<number, Set<number>>();
const maps = new Map<number, Map<number, bigint>>();

function create<T>(registry: Map<number, T>, value: T): number {
  const id = ids++;
  registry.set(id, value);
  return id;
}

// A structure by its handle; generated tests may name one first.
function get<T>(registry: Map<number, T>, id: number, empty: () => T): T {
  if (!registry.has(id)) registry.set(id, empty());
  return registry.get(id)!;
}

function maybe(value: bigint | undefined): data.Maybe<bigint> {
  return value === undefined ? new data.Nothing<bigint>() : new data.Just(value);
}

export function newQueue(value0: unknown): data.WorkQueue {
  return new data.WorkQueue(create(queues, []));
}

export async function offer(value0: data.WorkQueue, value1: number): Promise<void> {
  const items = get(queues, value0.id, () => []);
  items.push(value1);
}

export async function poll(value0: data.WorkQueue): Promise<data.Maybe<number>> {
  const items = get(queues, value0.id, () => []);
  return items.length > 0 ? new data.Just(items.shift()!) : new data.Nothing<number>();
}

export async function queueSize(value0: data.WorkQueue): Promise<bigint> {
  const items = get(queues, value0.id, () => []);
  return BigInt(items.length);
}

export function newTags(value0: unknown): data.Tags {
  return new data.Tags(create(sets, new Set<number>()));
}

export async function tag(value0: data.Tags, value1: number): Promise<boolean> {
  const items = get(sets, value0.id, () => new Set<number>());
  const added = !items.has(value1);
  items.add(value1);
  return added;
}

export async function untag(value0: data.Tags, value1: number): Promise<boolean> {
  const items = get(sets, value0.id, () => new Set<number>());
  return items.delete(value1);
}

export async function tagged(value0: data.Tags, value1: number): Promise<boolean> {
  const items = get(sets, value0.id, () => new Set<number>());
  return items.has(value1);
}

export function newCache(value0: unknown): data.Cache {
  return new data.Cache(create(maps, new Map<number, bigint>()));
}

export async function store(value0: data.Cache, value1: number, value2: bigint): Promise<data.Maybe<bigint>> {
  const entries = get(maps, value0.id, () => new Map<number, bigint>());
  const previous = entries.get(value1);
  entries.set(value1, value2);
  return maybe(previous);
}

export async function fetch(value0: data.Cache, value1: number): Promise<data.Maybe<bigint>> {
  const entries = get(maps, value0.id, () => new Map<number, bigint>());
  return maybe(entries.get(value1));
}

export async function evict(value0: data.Cache, value1: number): Promise<data.Maybe<bigint>> {
  const entries = get(maps, value0.id, () => new Map<number, bigint>());
  const previous = entries.get(value1);
  entries.delete(value1);
  return maybe(previous);
}
