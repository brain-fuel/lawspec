// User-owned LawSpec adapter.
package example;

import lawspec.runtime.LawSpecRuntime.Value;

public final class ScalarAdapters {
  // (Char -> Char)
  public static String echoChar(String value0) {
    throw new UnsupportedOperationException("echoChar -> Char");
  }

  // (CodePoint -> CodePoint)
  public static int echoCodePoint(int value0) {
    throw new UnsupportedOperationException("echoCodePoint -> CodePoint");
  }

  // (CodeUnit16 -> CodeUnit16)
  public static char echoCodeUnit(char value0) {
    throw new UnsupportedOperationException("echoCodeUnit -> CodeUnit16");
  }

  // (Bytes -> Bytes)
  public static byte[] echoBytes(byte[] value0) {
    throw new UnsupportedOperationException("echoBytes -> Bytes");
  }

  // (Complex64 -> Complex64)
  public static Value echoComplex(Value value0) {
    throw new UnsupportedOperationException("echoComplex -> Complex64");
  }

  // (Int8 -> BigInt)
  public static java.math.BigInteger successor(byte value0) {
    throw new UnsupportedOperationException("successor -> BigInt");
  }

  // (Int8 -> Int8)
  public static byte narrow(byte value0) {
    throw new UnsupportedOperationException("narrow -> Int8");
  }

  // (Decimal -> (Decimal -> Decimal))
  public static java.math.BigDecimal addDecimal(
      java.math.BigDecimal value0, java.math.BigDecimal value1) {
    throw new UnsupportedOperationException("addDecimal -> Decimal");
  }

  // (Symbol -> (Symbol -> Bool))
  public static boolean sameSymbol(Value value0, Value value1) {
    throw new UnsupportedOperationException("sameSymbol -> Bool");
  }

  // (Utf16Text -> Utf16Text)
  public static String echoRaw(String value0) {
    throw new UnsupportedOperationException("echoRaw -> Utf16Text");
  }

  // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
  public static Value echoPresence(Value value0) {
    throw new UnsupportedOperationException("echoPresence -> Optional (Nullable (Int8))");
  }

  // (Unit -> Unit)
  public static void finish(Value value0) {
    throw new UnsupportedOperationException("finish -> Unit");
  }

  // (UInt64 -> UInt64)
  public static java.math.BigInteger preserveBig(java.math.BigInteger value0) {
    throw new UnsupportedOperationException("preserveBig -> UInt64");
  }

  // (IntSize -> IntSize)
  public static Value machineEcho(Value value0) {
    throw new UnsupportedOperationException("machineEcho -> IntSize");
  }
}
