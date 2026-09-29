// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: Char
// LawSpec result: Char
export function echoChar(value0: string): string {
  return value0;
}

// LawSpec argument 0: CodePoint
// LawSpec result: CodePoint
export function echoCodePoint(value0: number): number {
  return value0;
}

// LawSpec argument 0: CodeUnit16
// LawSpec result: CodeUnit16
export function echoCodeUnit(value0: number): number {
  return value0;
}

// LawSpec argument 0: Bytes
// LawSpec result: Bytes
export function echoBytes(value0: Uint8Array): Uint8Array {
  return value0;
}

// LawSpec argument 0: Complex64
// LawSpec result: Complex64
export function echoComplex(value0: unknown): unknown {
  return value0;
}

// LawSpec argument 0: Int8
// LawSpec result: BigInt
export function successor(value0: number): bigint {
  return BigInt(value0) + 1n;
}

// LawSpec argument 0: Int8
// LawSpec result: Int8
export function narrow(value0: number): number {
  return value0;
}

// LawSpec argument 0: Decimal
// LawSpec argument 1: Decimal
// LawSpec result: Decimal
export function addDecimal(value0: unknown, value1: unknown): unknown {
  return ls.binary('+', value0, value1, 'Decimal', 'Decimal');
}

// LawSpec argument 0: Symbol
// LawSpec argument 1: Symbol
// LawSpec result: Bool
export function sameSymbol(value0: symbol, value1: symbol): boolean {
  return value0 === value1;
}

// LawSpec argument 0: Utf16Text
// LawSpec result: Utf16Text
export function echoRaw(value0: unknown): unknown {
  return value0;
}

// LawSpec argument 0: Optional (Nullable (Int8))
// LawSpec result: Optional (Nullable (Int8))
export function echoPresence(
    value0: data.Presence<data.Presence<number>>
): data.Presence<data.Presence<number>> {
  return value0;
}

// LawSpec argument 0: Unit
// LawSpec result: Unit
export function finish(value0: unknown): void {
  return;
}

// LawSpec argument 0: UInt64
// LawSpec result: UInt64
export function preserveBig(value0: bigint): bigint {
  return value0;
}

// LawSpec argument 0: IntSize
// LawSpec result: IntSize
export function machineEcho(value0: bigint): bigint {
  return value0;
}
