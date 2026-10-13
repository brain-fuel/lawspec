package example

@groovy.transform.CompileStatic
final class Refinements {
  static Number add(byte a, byte b) { (int) a + b }

  static Number successor(byte a) { (int) a + 1 }

  static Number count(String a) { a.codePointCount(0, a.length()) }

  static Number preserve(BigInteger a) { a }

  static byte positive(byte a) { a }

  static Number abstractEcho(BigInteger a) { a }
}
