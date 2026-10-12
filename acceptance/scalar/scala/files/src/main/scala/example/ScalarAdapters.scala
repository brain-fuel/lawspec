// User-owned LawSpec adapter.
package example

object ScalarAdapters {
  // (Char -> Char)
  def echoChar(value0: java.lang.String): java.lang.String = value0

  // (CodePoint -> CodePoint)
  def echoCodePoint(value0: scala.Int): scala.Int = value0

  // (CodeUnit16 -> CodeUnit16)
  def echoCodeUnit(value0: scala.Char): scala.Char = value0

  // (Bytes -> Bytes)
  def echoBytes(value0: scala.IArray[scala.Byte]): scala.IArray[scala.Byte] = value0

  // (Complex64 -> Complex64)
  def echoComplex(
    value0: lawspec.runtime.LawSpecRuntime.Complex,
  ): lawspec.runtime.LawSpecRuntime.Complex =
    value0

  // (Int8 -> BigInt)
  def successor(value0: scala.Byte): scala.math.BigInt = BigInt(value0.toLong + 1)

  // (Int8 -> Int8)
  def narrow(value0: scala.Byte): scala.Byte = value0

  // (Decimal -> (Decimal -> Decimal))
  def addDecimal(
    value0: scala.math.BigDecimal,
    value1: scala.math.BigDecimal,
  ): scala.math.BigDecimal =
    value0 + value1

  // (Symbol -> (Symbol -> Bool))
  def sameSymbol(
    value0: lawspec.runtime.LawSpecScala.Symbol,
    value1: lawspec.runtime.LawSpecScala.Symbol,
  ): scala.Boolean =
    value0 == value1

  // (Utf16Text -> Utf16Text)
  def echoRaw(value0: java.lang.String): java.lang.String = value0

  // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
  def echoPresence(
    value0: lawspec.runtime.LawSpecScala.Optional[
      lawspec.runtime.LawSpecScala.Nullable[scala.Byte]],
  ): lawspec.runtime.LawSpecScala.Optional[lawspec.runtime.LawSpecScala.Nullable[scala.Byte]] =
    value0

  // (Unit -> Unit)
  def finish(value0: scala.Unit): scala.Unit = ()

  // (UInt64 -> UInt64)
  def preserveBig(value0: scala.math.BigInt): scala.math.BigInt = value0

  // (IntSize -> IntSize)
  def machineEcho(value0: scala.math.BigInt): scala.math.BigInt = value0
}
