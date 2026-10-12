// User-owned LawSpec adapter.
package example

object Algebra {
  // (Integer -> (Integer -> Integer))
  def add(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0 + value1

  // (Integer -> (Integer -> Integer))
  def multiply(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0 * value1

  // (Integer -> Integer)
  def negateValue(value0: scala.math.BigInt): scala.Int | scala.Long | scala.math.BigInt =
    -value0

  // (Integer -> (Integer -> Integer))
  def maximumValue(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0.max(value1)

  // (Integer -> (Integer -> Integer))
  def subtractValue(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0 - value1

  // (Integer -> (Integer -> Integer))
  def divideLeft(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0 - value1

  // (Integer -> (Integer -> Integer))
  def divideRight(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0 + value1
}
