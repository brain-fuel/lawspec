// User-owned LawSpec adapter.

package example;

import lawspec.runtime.LawSpecRuntime.Value;

public final class ScalarAdapters
{
  // echoChar :: (Char -> Char) — scalar_adapters.lawspec:2
  public static String echoChar(String char1)
  {
    throw new UnsupportedOperationException("echoChar -> Char");
  }

  // echoCodePoint :: (CodePoint -> CodePoint) — scalar_adapters.lawspec:3
  public static int echoCodePoint(int codePoint1)
  {
    throw new UnsupportedOperationException("echoCodePoint -> CodePoint");
  }

  // echoCodeUnit :: (CodeUnit16 -> CodeUnit16) — scalar_adapters.lawspec:4
  public static char echoCodeUnit(char codeUnit16_1)
  {
    throw new UnsupportedOperationException("echoCodeUnit -> CodeUnit16");
  }

  // echoBytes :: (Bytes -> Bytes) — scalar_adapters.lawspec:5
  public static byte[] echoBytes(byte[] bytes1)
  {
    throw new UnsupportedOperationException("echoBytes -> Bytes");
  }

  // echoComplex :: (Complex64 -> Complex64) — scalar_adapters.lawspec:6
  public static Value echoComplex(Value complex64_1)
  {
    throw new UnsupportedOperationException("echoComplex -> Complex64");
  }

  // successor :: (Int8 -> Integer) — scalar_adapters.lawspec:7
  public static Number successor(byte int8_1)
  {
    throw new UnsupportedOperationException("successor -> Integer");
  }

  // narrow :: (Int8 -> Int8) — scalar_adapters.lawspec:8
  public static byte narrow(byte int8_1)
  {
    throw new UnsupportedOperationException("narrow -> Int8");
  }

  // addDecimal :: (Decimal -> (Decimal -> Decimal)) — scalar_adapters.lawspec:9
  public static java.math.BigDecimal addDecimal(
      java.math.BigDecimal decimal1, java.math.BigDecimal decimal2)
  {
    throw new UnsupportedOperationException("addDecimal -> Decimal");
  }

  // sameSymbol :: (Symbol -> (Symbol -> Bool)) — scalar_adapters.lawspec:10
  public static boolean sameSymbol(Value symbol1, Value symbol2)
  {
    throw new UnsupportedOperationException("sameSymbol -> Bool");
  }

  // echoRaw :: (Utf16Text -> Utf16Text) — scalar_adapters.lawspec:11
  public static String echoRaw(String utf16Text1)
  {
    throw new UnsupportedOperationException("echoRaw -> Utf16Text");
  }

  // echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable (Int8))) —
  // scalar_adapters.lawspec:12
  public static Value echoPresence(Value optional1)
  {
    throw new UnsupportedOperationException("echoPresence -> Optional (Nullable " + "(Int8))");
  }

  // finish :: (Unit -> Unit) — scalar_adapters.lawspec:13
  public static void finish(Value unit1)
  {
    throw new UnsupportedOperationException("finish -> Unit");
  }

  // preserveBig :: (UInt64 -> UInt64) — scalar_adapters.lawspec:14
  public static java.math.BigInteger preserveBig(java.math.BigInteger uint64_1)
  {
    throw new UnsupportedOperationException("preserveBig -> UInt64");
  }

  // machineEcho :: (IntSize -> IntSize) — scalar_adapters.lawspec:15
  public static Value machineEcho(Value intSize1)
  {
    throw new UnsupportedOperationException("machineEcho -> IntSize");
  }
}
