// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: Int32
// LawSpec result: Text
export function formatQuantity(value0: number): string {
  throw new Error('formatQuantity');
}

// LawSpec argument 0: Text
// LawSpec result: Int32
export function parseQuantity(value0: string): number {
  throw new Error('parseQuantity');
}
