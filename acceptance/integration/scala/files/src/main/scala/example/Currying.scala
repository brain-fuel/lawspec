package example

object Currying {
  def sumFour(a: BigInt, b: BigInt, c: BigInt, d: BigInt): scala.Int | scala.Long | scala.math.BigInt = a + b + c + d
  def format(prefix: String, enabled: Boolean, port: Int, suffix: String): String =
    prefix + (if (enabled) port.toString else "") + suffix
  def referenceFormat(prefix: String, enabled: Boolean, port: Int, suffix: String): String =
    List(prefix, if (enabled) port.toString else "", suffix).mkString("")
  def trim(x: String): String = x.trim
}
