// User-owned LawSpec adapter. class is a Java keyword, so the adapter is _class.
package example

@groovy.transform.CompileStatic
final class Keywords {
  static java.math.BigInteger _class(java.math.BigInteger value0) {
    return value0.shiftLeft(1)
  }
}
