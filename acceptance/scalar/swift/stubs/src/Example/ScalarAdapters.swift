// User-owned LawSpec adapter. Implement these functions.
import LawSpecRuntime

extension Example.ScalarAdapters {
    /// (Char -> Char)
    static func echoChar(_ value0: Unicode.Scalar) -> Unicode.Scalar {
        fatalError("not implemented: example.scalar_adapters::echoChar")
    }

    /// (CodePoint -> CodePoint)
    static func echoCodePoint(_ value0: UInt32) -> UInt32 {
        fatalError("not implemented: example.scalar_adapters::echoCodePoint")
    }

    /// (CodeUnit16 -> CodeUnit16)
    static func echoCodeUnit(_ value0: UInt16) -> UInt16 {
        fatalError("not implemented: example.scalar_adapters::echoCodeUnit")
    }

    /// (Bytes -> Bytes)
    static func echoBytes(_ value0: [UInt8]) -> [UInt8] {
        fatalError("not implemented: example.scalar_adapters::echoBytes")
    }

    /// (Complex64 -> Complex64)
    static func echoComplex(_ value0: Complex64) -> Complex64 {
        fatalError("not implemented: example.scalar_adapters::echoComplex")
    }

    /// (Int8 -> Integer)
    static func successor(_ value0: Int8) -> BigInt {
        fatalError("not implemented: example.scalar_adapters::successor")
    }

    /// (Int8 -> Int8)
    static func narrow(_ value0: Int8) -> Int8 {
        fatalError("not implemented: example.scalar_adapters::narrow")
    }

    /// (Decimal -> (Decimal -> Decimal))
    static func addDecimal(_ value0: ExactDecimal, _ value1: ExactDecimal) -> ExactDecimal {
        fatalError("not implemented: example.scalar_adapters::addDecimal")
    }

    /// (Symbol -> (Symbol -> Bool))
    static func sameSymbol(_ value0: Symbol, _ value1: Symbol) -> Bool {
        fatalError("not implemented: example.scalar_adapters::sameSymbol")
    }

    /// (Utf16Text -> Utf16Text)
    static func echoRaw(_ value0: [UInt16]) -> [UInt16] {
        fatalError("not implemented: example.scalar_adapters::echoRaw")
    }

    /// (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
    static func echoPresence(_ value0: Undefinable<Nullable<Int8>>) -> Undefinable<Nullable<Int8>> {
        fatalError("not implemented: example.scalar_adapters::echoPresence")
    }

    /// (Unit -> Unit)
    static func finish() {
        fatalError("not implemented: example.scalar_adapters::finish")
    }

    /// (UInt64 -> UInt64)
    static func preserveBig(_ value0: UInt64) -> UInt64 {
        fatalError("not implemented: example.scalar_adapters::preserveBig")
    }

    /// (IntSize -> IntSize)
    static func machineEcho(_ value0: Int) -> Int {
        fatalError("not implemented: example.scalar_adapters::machineEcho")
    }
}
