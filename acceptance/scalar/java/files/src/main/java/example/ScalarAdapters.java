// User-owned LawSpec adapter.
package example;
import lawspec.runtime.LawSpecRuntime;

import lawspec.runtime.LawSpecRuntime.Value;

public final class ScalarAdapters {
  // (Char -> Char)
  public static String echoChar(String value0) {
    return value0;
  }

  // (CodePoint -> CodePoint)
  public static int echoCodePoint(int value0) {
    return value0;
  }

  // (CodeUnit16 -> CodeUnit16)
  public static char echoCodeUnit(char value0) {
    return value0;
  }

  // (Bytes -> Bytes)
  public static byte[] echoBytes(byte[] value0) {
    return value0;
  }

  // (Complex64 -> Complex64)
  public static Value echoComplex(Value value0) {
    return value0;
  }

  // (Int8 -> BigInt)
  public static java.math.BigInteger successor(byte value0) {
    return java.math.BigInteger.valueOf(value0).add(java.math.BigInteger.ONE);
  }

  // (Int8 -> Int8)
  public static byte narrow(byte value0) {
    return value0;
  }

  // (Decimal -> (Decimal -> Decimal))
  public static java.math.BigDecimal addDecimal(
      java.math.BigDecimal value0, java.math.BigDecimal value1) {
    return value0.add(value1);
  }

  // (Symbol -> (Symbol -> Bool))
  public static boolean sameSymbol(Value value0, Value value1) {
    return LawSpecRuntime.equal(value0, value1);
  }

  // (Utf16Text -> Utf16Text)
  public static String echoRaw(String value0) {
    return value0;
  }

  // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
  public static Value echoPresence(Value value0) {
    return value0;
  }

  // (Unit -> Unit)
  public static void finish(Value value0) {
    return;
  }

  // (UInt64 -> UInt64)
  public static java.math.BigInteger preserveBig(java.math.BigInteger value0) {
    return value0;
  }

  // (IntSize -> IntSize)
  public static Value machineEcho(Value value0) {
    return value0;
  }
}
