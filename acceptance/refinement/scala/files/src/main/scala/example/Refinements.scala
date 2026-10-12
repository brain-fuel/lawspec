// User-owned LawSpec adapter.
package example

object Refinements {
  // (Int8 -> (Int8 -> Integer))
  def add(value0: scala.Byte, value1: scala.Byte): scala.Int | scala.Long | scala.math.BigInt =
    value0.toInt + value1.toInt

  // (Int8 -> Integer)
  def successor(value0: scala.Byte): scala.Int | scala.Long | scala.math.BigInt =
    value0.toInt + 1

  // (Text -> Integer)
  def count(value0: java.lang.String): scala.Int | scala.Long | scala.math.BigInt =
    value0.codePointCount(0, value0.length)

  // (UInt64 -> Integer)
  def preserve(value0: scala.math.BigInt): scala.Int | scala.Long | scala.math.BigInt =
    value0

  // (Int8 -> Int8)
  def positive(value0: scala.Byte): scala.Byte = value0

  // (Integer -> Integer)
  def abstractEcho(value0: scala.math.BigInt): scala.Int | scala.Long | scala.math.BigInt =
    value0
}
