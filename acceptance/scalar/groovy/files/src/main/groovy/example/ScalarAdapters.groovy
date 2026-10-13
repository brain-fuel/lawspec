// User-owned LawSpec adapter.
package example
import lawspec.runtime.LawSpecRuntime

import lawspec.runtime.LawSpecRuntime.Value

@groovy.transform.CompileStatic
final class ScalarAdapters {
  // (Char -> Char)
  static String echoChar(String value0) {
    return value0
  }

  // (CodePoint -> CodePoint)
  static int echoCodePoint(int value0) {
    return value0
  }

  // (CodeUnit16 -> CodeUnit16)
  static char echoCodeUnit(char value0) {
    return value0
  }

  // (Bytes -> Bytes)
  static byte[] echoBytes(byte[] value0) {
    return value0
  }

  // (Complex64 -> Complex64)
  static Value echoComplex(Value value0) {
    return value0
  }

  // (Int8 -> BigInt)
  static java.math.BigInteger successor(byte value0) {
    return java.math.BigInteger.valueOf(value0).add(java.math.BigInteger.ONE)
  }

  // (Int8 -> Int8)
  static byte narrow(byte value0) {
    return value0
  }

  // (Decimal -> (Decimal -> Decimal))
  static java.math.BigDecimal addDecimal(
      java.math.BigDecimal value0, java.math.BigDecimal value1) {
    return value0.add(value1)
  }

  // (Symbol -> (Symbol -> Bool))
  static boolean sameSymbol(Value value0, Value value1) {
    return LawSpecRuntime.equal(value0, value1)
  }

  // (Utf16Text -> Utf16Text)
  static String echoRaw(String value0) {
    return value0
  }

  // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
  static Value echoPresence(Value value0) {
    return value0
  }

  // (Unit -> Unit)
  static void finish(Value value0) {
    return
  }

  // (UInt64 -> UInt64)
  static java.math.BigInteger preserveBig(java.math.BigInteger value0) {
    return value0
  }

  // (IntSize -> IntSize)
  static Value machineEcho(Value value0) {
    return value0
  }
}
