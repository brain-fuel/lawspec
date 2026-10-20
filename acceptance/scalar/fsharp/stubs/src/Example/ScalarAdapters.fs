// User-owned LawSpec adapter. Implement these functions.
module Example.ScalarAdapters

/// (Char -> Char)
let echoChar (value0: System.Text.Rune) : System.Text.Rune =
    failwith "not implemented: example.scalar_adapters::echoChar"

/// (CodePoint -> CodePoint)
let echoCodePoint (value0: int) : int =
    failwith "not implemented: example.scalar_adapters::echoCodePoint"

/// (CodeUnit16 -> CodeUnit16)
let echoCodeUnit (value0: char) : char =
    failwith "not implemented: example.scalar_adapters::echoCodeUnit"

/// (Bytes -> Bytes)
let echoBytes (value0: byte[]) : byte[] =
    failwith "not implemented: example.scalar_adapters::echoBytes"

/// (Complex64 -> Complex64)
let echoComplex (value0: LawSpec.Complex64) : LawSpec.Complex64 =
    failwith "not implemented: example.scalar_adapters::echoComplex"

/// (Int8 -> Integer)
let successor (value0: sbyte) : bigint =
    failwith "not implemented: example.scalar_adapters::successor"

/// (Int8 -> Int8)
let narrow (value0: sbyte) : sbyte =
    failwith "not implemented: example.scalar_adapters::narrow"

/// (Decimal -> (Decimal -> Decimal))
let addDecimal (value0: LawSpec.ExactDecimal) (value1: LawSpec.ExactDecimal) : LawSpec.ExactDecimal =
    failwith "not implemented: example.scalar_adapters::addDecimal"

/// (Symbol -> (Symbol -> Bool))
let sameSymbol (value0: LawSpec.Symbol) (value1: LawSpec.Symbol) : bool =
    failwith "not implemented: example.scalar_adapters::sameSymbol"

/// (Utf16Text -> Utf16Text)
let echoRaw (value0: string) : string =
    failwith "not implemented: example.scalar_adapters::echoRaw"

/// (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
let echoPresence (value0: LawSpec.Optional<LawSpec.Nullable<sbyte>>) : LawSpec.Optional<LawSpec.Nullable<sbyte>> =
    failwith "not implemented: example.scalar_adapters::echoPresence"

/// (Unit -> Unit)
let finish (value0: unit) : unit =
    failwith "not implemented: example.scalar_adapters::finish"

/// (UInt64 -> UInt64)
let preserveBig (value0: uint64) : uint64 =
    failwith "not implemented: example.scalar_adapters::preserveBig"

/// (IntSize -> IntSize)
let machineEcho (value0: int64) : int64 =
    failwith "not implemented: example.scalar_adapters::machineEcho"
