// User-owned LawSpec adapter. Implement these functions.

import LawSpecRuntime

extension Example.ScalarAdapters {
  /// echoChar :: Char -> Char — scalar_adapters.lawspec:2
  static func echoChar(_ value0: Unicode.Scalar) -> Unicode.Scalar {
    fatalError("not implemented: example.scalar_adapters::echoChar")
  }

  /// echoCodePoint :: CodePoint -> CodePoint — scalar_adapters.lawspec:3
  static func echoCodePoint(_ value0: UInt32) -> UInt32 {
    fatalError("not implemented: example.scalar_adapters::echoCodePoint")
  }

  /// echoCodeUnit :: CodeUnit16 -> CodeUnit16 — scalar_adapters.lawspec:4
  static func echoCodeUnit(_ value0: UInt16) -> UInt16 {
    fatalError("not implemented: example.scalar_adapters::echoCodeUnit")
  }

  /// echoBytes :: Bytes -> Bytes — scalar_adapters.lawspec:5
  static func echoBytes(_ value0: [UInt8]) -> [UInt8] {
    fatalError("not implemented: example.scalar_adapters::echoBytes")
  }

  /// echoComplex :: Complex64 -> Complex64 — scalar_adapters.lawspec:6
  static func echoComplex(_ value0: Complex64) -> Complex64 {
    fatalError("not implemented: example.scalar_adapters::echoComplex")
  }

  /// successor :: Int8 -> Integer — scalar_adapters.lawspec:7
  static func successor(_ value0: Int8) -> BigInt {
    fatalError("not implemented: example.scalar_adapters::successor")
  }

  /// narrow :: Int8 -> Int8 — scalar_adapters.lawspec:8
  static func narrow(_ value0: Int8) -> Int8 {
    fatalError("not implemented: example.scalar_adapters::narrow")
  }

  /// addDecimal :: Decimal -> Decimal -> Decimal — scalar_adapters.lawspec:9
  static func addDecimal(_ value0: ExactDecimal, _ value1: ExactDecimal) -> ExactDecimal {
    fatalError("not implemented: example.scalar_adapters::addDecimal")
  }

  /// sameSymbol :: Symbol -> Symbol -> Bool — scalar_adapters.lawspec:10
  static func sameSymbol(_ value0: Symbol, _ value1: Symbol) -> Bool {
    fatalError("not implemented: example.scalar_adapters::sameSymbol")
  }

  /// echoRaw :: Utf16Text -> Utf16Text — scalar_adapters.lawspec:11
  static func echoRaw(_ value0: [UInt16]) -> [UInt16] {
    fatalError("not implemented: example.scalar_adapters::echoRaw")
  }

  /// echoPresence :: Optional (Nullable (Int8)) -> Optional (Nullable (Int8)) —
  /// scalar_adapters.lawspec:12
  static func echoPresence(_ value0: Undefinable<Nullable<Int8>>) -> Undefinable<Nullable<Int8>> {
    fatalError("not implemented: example.scalar_adapters::echoPresence")
  }

  /// finish :: Unit -> Unit — scalar_adapters.lawspec:13
  static func finish() {
    fatalError("not implemented: example.scalar_adapters::finish")
  }

  /// preserveBig :: UInt64 -> UInt64 — scalar_adapters.lawspec:14
  static func preserveBig(_ value0: UInt64) -> UInt64 {
    fatalError("not implemented: example.scalar_adapters::preserveBig")
  }

  /// machineEcho :: IntSize -> IntSize — scalar_adapters.lawspec:15
  static func machineEcho(_ value0: Int) -> Int {
    fatalError("not implemented: example.scalar_adapters::machineEcho")
  }
}
