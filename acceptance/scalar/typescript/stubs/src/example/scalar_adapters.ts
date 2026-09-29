// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: Char
// LawSpec result: Char
export function echoChar(value0: string): string {
  throw new Error('echoChar');
}

// LawSpec argument 0: CodePoint
// LawSpec result: CodePoint
export function echoCodePoint(value0: number): number {
  throw new Error('echoCodePoint');
}

// LawSpec argument 0: CodeUnit16
// LawSpec result: CodeUnit16
export function echoCodeUnit(value0: number): number {
  throw new Error('echoCodeUnit');
}

// LawSpec argument 0: Bytes
// LawSpec result: Bytes
export function echoBytes(value0: Uint8Array): Uint8Array {
  throw new Error('echoBytes');
}

// LawSpec argument 0: Complex64
// LawSpec result: Complex64
export function echoComplex(value0: unknown): unknown {
  throw new Error('echoComplex');
}

// LawSpec argument 0: Int8
// LawSpec result: BigInt
export function successor(value0: number): bigint {
  throw new Error('successor');
}

// LawSpec argument 0: Int8
// LawSpec result: Int8
export function narrow(value0: number): number {
  throw new Error('narrow');
}

// LawSpec argument 0: Decimal
// LawSpec argument 1: Decimal
// LawSpec result: Decimal
export function addDecimal(value0: unknown, value1: unknown): unknown {
  throw new Error('addDecimal');
}

// LawSpec argument 0: Symbol
// LawSpec argument 1: Symbol
// LawSpec result: Bool
export function sameSymbol(value0: symbol, value1: symbol): boolean {
  throw new Error('sameSymbol');
}

// LawSpec argument 0: Utf16Text
// LawSpec result: Utf16Text
export function echoRaw(value0: unknown): unknown {
  throw new Error('echoRaw');
}

// LawSpec argument 0: Optional (Nullable (Int8))
// LawSpec result: Optional (Nullable (Int8))
export function echoPresence(
    value0: data.Presence<data.Presence<number>>
): data.Presence<data.Presence<number>> {
  throw new Error('echoPresence');
}

// LawSpec argument 0: Unit
// LawSpec result: Unit
export function finish(value0: unknown): void {
  throw new Error('finish');
}

// LawSpec argument 0: UInt64
// LawSpec result: UInt64
export function preserveBig(value0: bigint): bigint {
  throw new Error('preserveBig');
}

// LawSpec argument 0: IntSize
// LawSpec result: IntSize
export function machineEcho(value0: bigint): bigint {
  throw new Error('machineEcho');
}
