// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// LawSpec argument char1: Char
// LawSpec result: Char
export function echoChar(char1: string): string
{
  throw new Error('echoChar');
}

// LawSpec argument codePoint1: CodePoint
// LawSpec result: CodePoint
export function echoCodePoint(codePoint1: number): number
{
  throw new Error('echoCodePoint');
}

// LawSpec argument codeUnit16_1: CodeUnit16
// LawSpec result: CodeUnit16
export function echoCodeUnit(codeUnit16_1: number): number
{
  throw new Error('echoCodeUnit');
}

// LawSpec argument bytes1: Bytes
// LawSpec result: Bytes
export function echoBytes(bytes1: Uint8Array): Uint8Array
{
  throw new Error('echoBytes');
}

// LawSpec argument complex64_1: Complex64
// LawSpec result: Complex64
export function echoComplex(complex64_1: unknown): unknown
{
  throw new Error('echoComplex');
}

// LawSpec argument int8_1: Int8
// LawSpec result: Integer
export function successor(int8_1: number): number | bigint
{
  throw new Error('successor');
}

// LawSpec argument int8_1: Int8
// LawSpec result: Int8
export function narrow(int8_1: number): number
{
  throw new Error('narrow');
}

// LawSpec argument decimal1: Decimal
// LawSpec argument decimal2: Decimal
// LawSpec result: Decimal
export function addDecimal(decimal1: unknown, decimal2: unknown): unknown
{
  throw new Error('addDecimal');
}

// LawSpec argument symbol1: Symbol
// LawSpec argument symbol2: Symbol
// LawSpec result: Bool
export function sameSymbol(symbol1: symbol, symbol2: symbol): boolean
{
  throw new Error('sameSymbol');
}

// LawSpec argument utf16Text1: Utf16Text
// LawSpec result: Utf16Text
export function echoRaw(utf16Text1: unknown): unknown
{
  throw new Error('echoRaw');
}

// LawSpec argument optional1: Optional (Nullable (Int8))
// LawSpec result: Optional (Nullable (Int8))
export function echoPresence(
  optional1: data.Presence<data.Presence<number>>,
): data.Presence<data.Presence<number>>
{
  throw new Error('echoPresence');
}

// LawSpec argument unit1: Unit
// LawSpec result: Unit
export function finish(unit1: unknown): void
{
  throw new Error('finish');
}

// LawSpec argument uint64_1: UInt64
// LawSpec result: UInt64
export function preserveBig(uint64_1: bigint): bigint
{
  throw new Error('preserveBig');
}

// LawSpec argument intSize1: IntSize
// LawSpec result: IntSize
export function machineEcho(intSize1: bigint): bigint
{
  throw new Error('machineEcho');
}
