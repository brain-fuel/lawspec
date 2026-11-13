// User-owned LawSpec adapter. Implement these functions.
module Example.ScalarAdapters

/// (Char -> Char)
let echoChar (char1: System.Text.Rune) : System.Text.Rune =
    failwith "not implemented: example.scalar_adapters::echoChar"

/// (CodePoint -> CodePoint)
let echoCodePoint (codePoint1: int) : int =
    failwith "not implemented: example.scalar_adapters::echoCodePoint"

/// (CodeUnit16 -> CodeUnit16)
let echoCodeUnit (codeUnit16_1: char) : char =
    failwith "not implemented: example.scalar_adapters::echoCodeUnit"

/// (Bytes -> Bytes)
let echoBytes (bytes1: byte[]) : byte[] =
    failwith "not implemented: example.scalar_adapters::echoBytes"

/// (Complex64 -> Complex64)
let echoComplex (complex64_1: LawSpec.Complex64) : LawSpec.Complex64 =
    failwith "not implemented: example.scalar_adapters::echoComplex"

/// (Int8 -> Integer)
let successor (int8_1: sbyte) : bigint =
    failwith "not implemented: example.scalar_adapters::successor"

/// (Int8 -> Int8)
let narrow (int8_1: sbyte) : sbyte =
    failwith "not implemented: example.scalar_adapters::narrow"

/// (Decimal -> (Decimal -> Decimal))
let addDecimal (decimal1: LawSpec.ExactDecimal) (decimal2: LawSpec.ExactDecimal) : LawSpec.ExactDecimal =
    failwith "not implemented: example.scalar_adapters::addDecimal"

/// (Symbol -> (Symbol -> Bool))
let sameSymbol (symbol1: LawSpec.Symbol) (symbol2: LawSpec.Symbol) : bool =
    failwith "not implemented: example.scalar_adapters::sameSymbol"

/// (Utf16Text -> Utf16Text)
let echoRaw (utf16Text1: string) : string =
    failwith "not implemented: example.scalar_adapters::echoRaw"

/// (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
let echoPresence (optional1: LawSpec.Optional<LawSpec.Nullable<sbyte>>) : LawSpec.Optional<LawSpec.Nullable<sbyte>> =
    failwith "not implemented: example.scalar_adapters::echoPresence"

/// (Unit -> Unit)
let finish (unit1: unit) : unit =
    failwith "not implemented: example.scalar_adapters::finish"

/// (UInt64 -> UInt64)
let preserveBig (uint64_1: uint64) : uint64 =
    failwith "not implemented: example.scalar_adapters::preserveBig"

/// (IntSize -> IntSize)
let machineEcho (intSize1: int64) : int64 =
    failwith "not implemented: example.scalar_adapters::machineEcho"
