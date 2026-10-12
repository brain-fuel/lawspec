// User-owned LawSpec adapter.
package example

object Currying {
  // (Integer -> (Integer -> (Integer -> (Integer -> Integer))))
  def sumFour(
    value0: scala.math.BigInt,
    value1: scala.math.BigInt,
    value2: scala.math.BigInt,
    value3: scala.math.BigInt,
  ): scala.Int | scala.Long | scala.math.BigInt =
    value0 + value1 + value2 + value3

  // (Text -> (Bool -> (Int32 -> (Text -> Text))))
  def format(
    value0: java.lang.String,
    value1: scala.Boolean,
    value2: scala.Int,
    value3: java.lang.String,
  ): java.lang.String =
    value0 + (if (value1) value2.toString else "") + value3

  // (Text -> (Bool -> (Int32 -> (Text -> Text))))
  def referenceFormat(
    value0: java.lang.String,
    value1: scala.Boolean,
    value2: scala.Int,
    value3: java.lang.String,
  ): java.lang.String =
    List(value0, if (value1) value2.toString else "", value3).mkString

  // (Text -> Text)
  def trim(value0: java.lang.String): java.lang.String = value0.trim
}
