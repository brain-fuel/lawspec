package example

object Algebra {
  type Integer = scala.Int | scala.Long | scala.math.BigInt
  def add(x: BigInt, y: BigInt): Integer = x + y
  def multiply(x: BigInt, y: BigInt): Integer = x * y
  def negateValue(x: BigInt): Integer = -x
  def maximumValue(x: BigInt, y: BigInt): Integer = x.max(y)
  def subtractValue(x: BigInt, y: BigInt): Integer = x - y
  def divideLeft(x: BigInt, y: BigInt): Integer = x - y
  def divideRight(x: BigInt, y: BigInt): Integer = x + y
}
