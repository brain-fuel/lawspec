// User-owned LawSpec adapters for the resources example.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { execFileSync } from 'node:child_process';
import * as data from '.././lawspec_data.js';

// An in-memory store. At most three may be open at once, so a store that is
// never closed is noticed.
let openCount = 0;
class Store {
  items: Map<number, number>;
  open: boolean;
  constructor() {
    if (openCount >= 3) throw new Error('too many open stores: one was never closed');
    openCount += 1;
    this.items = new Map();
    this.open = true;
  }
  close() {
    if (this.open) { this.open = false; openCount -= 1; }
  }
}

// LawSpec argument 0: Unit
// LawSpec result: example.resources::type::Store
export function openStore(value0: unknown): unknown {
  return new Store();
}

// LawSpec argument 0: example.resources::type::Store
// LawSpec result: Unit
export function closeStore(value0: unknown): void {
  (value0 as Store).close();
}

// LawSpec argument 0: example.resources::type::Store
// LawSpec result: Unit
export function clearStore(value0: unknown): void {
  (value0 as Store).items.clear();
}

// LawSpec argument 0: example.resources::type::Store
// LawSpec argument 1: Int32
// LawSpec argument 2: Int32
// LawSpec result: Unit
export function put(value0: unknown, value1: number, value2: number): void {
  const store = value0 as Store;
  if (!store.open) throw new Error('the store is closed');
  store.items.set(value1, value2);
}

// LawSpec argument 0: example.resources::type::Store
// LawSpec argument 1: Int32
// LawSpec result: Maybe (Int32)
export function get(value0: unknown, value1: number): data.Maybe<number> {
  const store = value0 as Store;
  if (!store.open) throw new Error('the store is closed');
  return store.items.has(value1) ? new data.Just(store.items.get(value1)!) : new data.Nothing<number>();
}

// LawSpec argument 0: example.resources::type::Store
// LawSpec result: Bool
export function isOpen(value0: unknown): boolean {
  return (value0 as Store).open;
}

// LawSpec argument 0: example.resources::type::Store
// LawSpec result: Int32
export function size(value0: unknown): number {
  return (value0 as Store).items.size;
}

// LawSpec argument 0: Text
// LawSpec argument 1: Int32
// LawSpec result: Unit
export function writeNote(value0: string, value1: number): void {
  fs.writeFileSync(path.join(value0, 'note.txt'), String(value1));
}

// LawSpec argument 0: Text
// LawSpec result: Maybe (Int32)
export function readNote(value0: string): data.Maybe<number> {
  const file = path.join(value0, 'note.txt');
  return fs.existsSync(file) ? new data.Just(Number(fs.readFileSync(file, 'utf8'))) : new data.Nothing<number>();
}

// LawSpec argument 0: Int32
// LawSpec result: Bool
export function canListen(value0: number): boolean {
  const script = `const s=require('net').createServer();s.on('error',()=>process.exit(1));s.listen(${value0},'127.0.0.1',()=>s.close());`;
  try {
    execFileSync(process.execPath, ['-e', script]);
    return true;
  } catch {
    return false;
  }
}

// LawSpec argument 0: Int32
// LawSpec result: Unit
export function setGreeting(value0: number): void {
  process.env.LAWSPEC_EXAMPLE_GREETING = String(value0);
}

// LawSpec argument 0: Unit
// LawSpec result: Maybe (Int32)
export function greeting(value0: unknown): data.Maybe<number> {
  const value = process.env.LAWSPEC_EXAMPLE_GREETING;
  return value === undefined ? new data.Nothing<number>() : new data.Just(Number(value));
}
