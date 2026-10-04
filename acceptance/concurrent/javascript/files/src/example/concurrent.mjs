// User-owned LawSpec adapter: a queue, a set and a map shared between
// tasks. JavaScript runs one task at a time, so each structure is atomic as
// long as no call awaits between reading and writing it.
import * as data from '.././lawspec_data.mjs';

let ids = 0;
const queues = new Map();
const sets = new Map();
const maps = new Map();

function create(registry, value) {
  const id = ids++;
  registry.set(id, value);
  return id;
}

// A structure by its handle; generated tests may name one first.
function get(registry, id, empty) {
  if (!registry.has(id)) registry.set(id, empty());
  return registry.get(id);
}

function maybe(value) {
  return value === undefined ? new data.Nothing() : new data.Just(value);
}

export function newQueue(value0) {
  return new data.WorkQueue(create(queues, []));
}

export async function offer(value0, value1) {
  const items = get(queues, value0.id, () => []);
  items.push(value1);
}

export async function poll(value0) {
  const items = get(queues, value0.id, () => []);
  return items.length > 0 ? new data.Just(items.shift()) : new data.Nothing();
}

export async function queueSize(value0) {
  const items = get(queues, value0.id, () => []);
  return BigInt(items.length);
}

export function newTags(value0) {
  return new data.Tags(create(sets, new Set()));
}

export async function tag(value0, value1) {
  const items = get(sets, value0.id, () => new Set());
  const added = !items.has(value1);
  items.add(value1);
  return added;
}

export async function untag(value0, value1) {
  const items = get(sets, value0.id, () => new Set());
  return items.delete(value1);
}

export async function tagged(value0, value1) {
  const items = get(sets, value0.id, () => new Set());
  return items.has(value1);
}

export function newCache(value0) {
  return new data.Cache(create(maps, new Map()));
}

export async function store(value0, value1, value2) {
  const entries = get(maps, value0.id, () => new Map());
  const previous = entries.get(value1);
  entries.set(value1, value2);
  return maybe(previous);
}

export async function fetch(value0, value1) {
  const entries = get(maps, value0.id, () => new Map());
  return maybe(entries.get(value1));
}

export async function evict(value0, value1) {
  const entries = get(maps, value0.id, () => new Map());
  const previous = entries.get(value1);
  entries.delete(value1);
  return maybe(previous);
}
