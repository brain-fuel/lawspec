// User-owned LawSpec adapter.
// Native Swift adapters exercise the checked Swift scalar bridge.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.ScalarAdapters {
    /// (Char -> Char)
    static func echoChar(_ value0: Unicode.Scalar) -> Unicode.Scalar {
        value0
    }

    /// (CodePoint -> CodePoint)
    static func echoCodePoint(_ value0: UInt32) -> UInt32 {
        value0
    }

    /// (CodeUnit16 -> CodeUnit16)
    static func echoCodeUnit(_ value0: UInt16) -> UInt16 {
        value0
    }

    /// (Bytes -> Bytes)
    static func echoBytes(_ value0: [UInt8]) -> [UInt8] {
        value0
    }

    /// (Complex64 -> Complex64)
    static func echoComplex(_ value0: Complex64) -> Complex64 {
        value0
    }

    /// (Int8 -> Integer)
    static func successor(_ value0: Int8) -> BigInt {
        BigInt(value0) + 1
    }

    /// (Int8 -> Int8)
    static func narrow(_ value0: Int8) -> Int8 {
        value0
    }

    /// (Decimal -> (Decimal -> Decimal))
    static func addDecimal(_ value0: ExactDecimal, _ value1: ExactDecimal) -> ExactDecimal {
        value0 + value1
    }

    /// (Symbol -> (Symbol -> Bool))
    static func sameSymbol(_ value0: Symbol, _ value1: Symbol) -> Bool {
        value0 == value1
    }

    /// (Utf16Text -> Utf16Text)
    static func echoRaw(_ value0: [UInt16]) -> [UInt16] {
        value0
    }

    /// (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
    static func echoPresence(_ value0: Undefinable<Nullable<Int8>>) -> Undefinable<Nullable<Int8>> {
        value0
    }

    /// (Unit -> Unit)
    static func finish() {
    }

    /// (UInt64 -> UInt64)
    static func preserveBig(_ value0: UInt64) -> UInt64 {
        value0
    }

    /// (IntSize -> IntSize)
    static func machineEcho(_ value0: Int) -> Int {
        value0
    }
}
