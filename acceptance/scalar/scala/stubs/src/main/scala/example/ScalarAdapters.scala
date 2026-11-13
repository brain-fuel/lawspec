// User-owned LawSpec adapter.
package example

object ScalarAdapters {
  // echoChar :: (Char -> Char) — scalar_adapters.lawspec:2
  def echoChar(char1: java.lang.String): java.lang.String =
    throw NotImplementedError("echoChar")

  // echoCodePoint :: (CodePoint -> CodePoint) — scalar_adapters.lawspec:3
  def echoCodePoint(codePoint1: scala.Int): scala.Int =
    throw NotImplementedError("echoCodePoint")

  // echoCodeUnit :: (CodeUnit16 -> CodeUnit16) — scalar_adapters.lawspec:4
  def echoCodeUnit(codeUnit16_1: scala.Char): scala.Char =
    throw NotImplementedError("echoCodeUnit")

  // echoBytes :: (Bytes -> Bytes) — scalar_adapters.lawspec:5
  def echoBytes(bytes1: scala.IArray[scala.Byte]): scala.IArray[scala.Byte] =
    throw NotImplementedError("echoBytes")

  // echoComplex :: (Complex64 -> Complex64) — scalar_adapters.lawspec:6
  def echoComplex(
      complex64_1: lawspec.runtime.LawSpecRuntime.Complex
  ): lawspec.runtime.LawSpecRuntime.Complex =
    throw NotImplementedError("echoComplex")

  // successor :: (Int8 -> Integer) — scalar_adapters.lawspec:7
  def successor(
      int8_1: scala.Byte
  ): scala.Int | scala.Long | scala.math.BigInt =
    throw NotImplementedError("successor")

  // narrow :: (Int8 -> Int8) — scalar_adapters.lawspec:8
  def narrow(int8_1: scala.Byte): scala.Byte =
    throw NotImplementedError("narrow")

  // addDecimal :: (Decimal -> (Decimal -> Decimal)) — scalar_adapters.lawspec:9
  def addDecimal(
      decimal1: scala.math.BigDecimal,
      decimal2: scala.math.BigDecimal
  ): scala.math.BigDecimal =
    throw NotImplementedError("addDecimal")

  // sameSymbol :: (Symbol -> (Symbol -> Bool)) — scalar_adapters.lawspec:10
  def sameSymbol(
      symbol1: lawspec.runtime.LawSpecScala.Symbol,
      symbol2: lawspec.runtime.LawSpecScala.Symbol
  ): scala.Boolean =
    throw NotImplementedError("sameSymbol")

  // echoRaw :: (Utf16Text -> Utf16Text) — scalar_adapters.lawspec:11
  def echoRaw(utf16Text1: java.lang.String): java.lang.String =
    throw NotImplementedError("echoRaw")

  // echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
  // — scalar_adapters.lawspec:12
  def echoPresence(
      optional1: lawspec.runtime.LawSpecScala.Optional[
        lawspec.runtime.LawSpecScala.Nullable[scala.Byte]
      ]
  ): lawspec.runtime.LawSpecScala.Optional[
    lawspec.runtime.LawSpecScala.Nullable[scala.Byte]
  ] =
    throw NotImplementedError("echoPresence")

  // finish :: (Unit -> Unit) — scalar_adapters.lawspec:13
  def finish(unit1: scala.Unit): scala.Unit =
    throw NotImplementedError("finish")

  // preserveBig :: (UInt64 -> UInt64) — scalar_adapters.lawspec:14
  def preserveBig(uint64_1: scala.math.BigInt): scala.math.BigInt =
    throw NotImplementedError("preserveBig")

  // machineEcho :: (IntSize -> IntSize) — scalar_adapters.lawspec:15
  def machineEcho(intSize1: scala.math.BigInt): scala.math.BigInt =
    throw NotImplementedError("machineEcho")
}
