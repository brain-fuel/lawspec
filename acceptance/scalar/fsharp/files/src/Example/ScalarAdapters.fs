// User-owned LawSpec adapter.
// Native F# adapters exercise the checked .NET scalar bridge.
// ref:DEC-acceptance-with-mutants
module Example.ScalarAdapters

/// (Char -> Char)
let echoChar (value0: System.Text.Rune) : System.Text.Rune = value0

/// (CodePoint -> CodePoint)
let echoCodePoint (value0: int) : int = value0

/// (CodeUnit16 -> CodeUnit16)
let echoCodeUnit (value0: char) : char = value0

/// (Bytes -> Bytes)
let echoBytes (value0: byte[]) : byte[] = value0

/// (Complex64 -> Complex64)
let echoComplex (value0: LawSpec.Complex64) : LawSpec.Complex64 = value0

/// (Int8 -> BigInt)
let successor (value0: sbyte) : bigint = bigint value0 + 1I

/// (Int8 -> Int8)
let narrow (value0: sbyte) : sbyte = value0

/// (Decimal -> (Decimal -> Decimal))
let addDecimal (value0: LawSpec.ExactDecimal) (value1: LawSpec.ExactDecimal) : LawSpec.ExactDecimal =
    value0 + value1

/// (Symbol -> (Symbol -> Bool))
let sameSymbol (value0: LawSpec.Symbol) (value1: LawSpec.Symbol) : bool = value0 = value1

/// (Utf16Text -> Utf16Text)
let echoRaw (value0: string) : string = value0

/// (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
let echoPresence (value0: LawSpec.Optional<LawSpec.Nullable<sbyte>>) : LawSpec.Optional<LawSpec.Nullable<sbyte>> =
    value0

/// (Unit -> Unit)
let finish (value0: unit) : unit = value0

/// (UInt64 -> UInt64)
let preserveBig (value0: uint64) : uint64 = value0

/// (IntSize -> IntSize)
let machineEcho (value0: int64) : int64 = value0
