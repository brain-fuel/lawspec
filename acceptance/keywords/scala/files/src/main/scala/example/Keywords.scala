// User-owned LawSpec adapter. class is a Scala keyword, so the adapter is _class.
package example

object Keywords {
  // (BigInt -> BigInt)
  def _class(value0: scala.math.BigInt): scala.math.BigInt = value0 << 1
}
