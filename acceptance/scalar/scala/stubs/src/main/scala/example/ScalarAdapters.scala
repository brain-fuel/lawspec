// User-owned LawSpec adapter.
package example

object ScalarAdapters {
  // (Char -> Char)
  def echoChar(value0: java.lang.String): java.lang.String = throw NotImplementedError("echoChar")

  // (CodePoint -> CodePoint)
  def echoCodePoint(value0: scala.Int): scala.Int = throw NotImplementedError("echoCodePoint")

  // (CodeUnit16 -> CodeUnit16)
  def echoCodeUnit(value0: scala.Char): scala.Char = throw NotImplementedError("echoCodeUnit")

  // (Bytes -> Bytes)
  def echoBytes(value0: scala.IArray[scala.Byte]): scala.IArray[scala.Byte] =
    throw NotImplementedError("echoBytes")

  // (Complex64 -> Complex64)
  def echoComplex(
    value0: lawspec.runtime.LawSpecRuntime.Complex,
  ): lawspec.runtime.LawSpecRuntime.Complex =
    throw NotImplementedError("echoComplex")

  // (Int8 -> Integer)
  def successor(value0: scala.Byte): scala.Int | scala.Long | scala.math.BigInt =
    throw NotImplementedError("successor")

  // (Int8 -> Int8)
  def narrow(value0: scala.Byte): scala.Byte = throw NotImplementedError("narrow")

  // (Decimal -> (Decimal -> Decimal))
  def addDecimal(
    value0: scala.math.BigDecimal,
    value1: scala.math.BigDecimal,
  ): scala.math.BigDecimal =
    throw NotImplementedError("addDecimal")

  // (Symbol -> (Symbol -> Bool))
  def sameSymbol(
    value0: lawspec.runtime.LawSpecScala.Symbol,
    value1: lawspec.runtime.LawSpecScala.Symbol,
  ): scala.Boolean =
    throw NotImplementedError("sameSymbol")

  // (Utf16Text -> Utf16Text)
  def echoRaw(value0: java.lang.String): java.lang.String = throw NotImplementedError("echoRaw")

  // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
  def echoPresence(
    value0: lawspec.runtime.LawSpecScala.Optional[
      lawspec.runtime.LawSpecScala.Nullable[scala.Byte]],
  ): lawspec.runtime.LawSpecScala.Optional[lawspec.runtime.LawSpecScala.Nullable[scala.Byte]] =
    throw NotImplementedError("echoPresence")

  // (Unit -> Unit)
  def finish(value0: scala.Unit): scala.Unit = throw NotImplementedError("finish")

  // (UInt64 -> UInt64)
  def preserveBig(value0: scala.math.BigInt): scala.math.BigInt =
    throw NotImplementedError("preserveBig")

  // (IntSize -> IntSize)
  def machineEcho(value0: scala.math.BigInt): scala.math.BigInt =
    throw NotImplementedError("machineEcho")
}
