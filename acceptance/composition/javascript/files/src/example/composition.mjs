// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
import * as data from '.././lawspec_data.mjs';
import * as schema from '.././lawspec_schema.mjs';
import * as ls from '../lawspec_runtime.mjs';

/** An in-memory log store: each log's records, newest last. */
class Store {
  logs = new Map();
  open = true;
}

// LawSpec argument 0: Unit
// LawSpec result: example.composition::type::Store
export function openStore(value0) {
  return new Store();
}

// LawSpec argument 0: example.composition::type::Store
// LawSpec result: Unit
export function closeStore(value0) {
  value0.open = false;
}

/** The native handler of Logs: create, append. */
export class LogsHandler {
  constructor(resource) {
    this.resource = resource;
  }
  create(value0) {
    this.resource.logs.set(value0, []);
  }
  append(value0, value1) {
    const records = this.resource.logs.get(value0);
    if (records === undefined) throw new ls.Fail(new data.ProblemUnknownLog());
    if (value1 === '') throw new ls.Fail(new data.ProblemEmptyRecord());
    records.push(value1);
    return BigInt(records.length - 1);
  }
}

/** The native handler of Reader: size. */
export class ReaderHandler {
  constructor(resource) {
    this.resource = resource;
  }
  size(value0) {
    const records = this.resource.logs.get(value0);
    return records === undefined ? new data.Absent() : new data.Present(BigInt(records.length));
  }
}

/** The native handler of Writer: write, lastOffset. */
export class WriterHandler {
  constructor(resource) {
    this.resource = resource;
    this.last = new data.Absent();
  }
  write(value0, value1) {
    const records = this.resource.logs.get(value0);
    if (records === undefined || value1 === '') return false;
    records.push(value1);
    this.last = new data.Present(BigInt(records.length - 1));
    return true;
  }
  lastOffset() {
    return this.last;
  }
}
