// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import type * as abilities from '.././lawspec_abilities/example/composition.js';
import * as ls from '../lawspec_runtime.js';

/** An in-memory log store: each log's records, newest last. */
class Store {
  logs = new Map<string, string[]>();
  open = true;
}

// LawSpec argument 0: Unit
// LawSpec result: example.composition::type::Store
export function openStore(value0: unknown): unknown {
  return new Store();
}

// LawSpec argument 0: example.composition::type::Store
// LawSpec result: Unit
export function closeStore(value0: unknown): void {
  (value0 as Store).open = false;
}

/** The native handler of Logs: create, append. */
export class LogsHandler implements abilities.Logs {
  resource: unknown;
  constructor(resource: unknown) {
    this.resource = resource;
  }
  create(value0: string): void {
    (this.resource as Store).logs.set(value0, []);
  }
  append(value0: string, value1: string): bigint {
    const records = (this.resource as Store).logs.get(value0);
    if (records === undefined) throw new ls.Fail(new data.ProblemUnknownLog());
    if (value1 === '') throw new ls.Fail(new data.ProblemEmptyRecord());
    records.push(value1);
    return BigInt(records.length - 1);
  }
}

/** The native handler of Reader: size. */
export class ReaderHandler implements abilities.Reader {
  resource: unknown;
  constructor(resource: unknown) {
    this.resource = resource;
  }
  size(value0: string): data.Maybe<bigint> {
    const records = (this.resource as Store).logs.get(value0);
    return records === undefined ? new data.Nothing() : new data.Just(BigInt(records.length));
  }
}

/** The native handler of Writer: write, lastOffset. */
export class WriterHandler implements abilities.Writer {
  resource: unknown;
  last: data.Maybe<bigint> = new data.Nothing();
  constructor(resource: unknown) {
    this.resource = resource;
  }
  write(value0: string, value1: string): boolean {
    const records = (this.resource as Store).logs.get(value0);
    if (records === undefined || value1 === '') return false;
    records.push(value1);
    this.last = new data.Just(BigInt(records.length - 1));
    return true;
  }
  lastOffset(): data.Maybe<bigint> {
    return this.last;
  }
}
