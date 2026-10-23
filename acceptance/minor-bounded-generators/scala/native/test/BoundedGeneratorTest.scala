// Generated from templates/acceptance/minor-bounded-generators/scala/native/test/BoundedGeneratorTest.scala by lawspec-dev generate. Do not edit.
package lawspec

import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime
import lawspec.testing.{Arb, Rng, Tree}
import org.scalatest.funsuite.AnyFunSuite

private case class RangeCase(
  name: String, bits: Int, lower: BigInteger, upper: BigInteger,
  generator: Arb[LawSpecRuntime.Value],
)

class BoundedGeneratorTest extends AnyFunSuite:
  private val cases = List(
    RangeCase("Int64", 32, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.bounded("Int64", "1", "9223372036854775807")
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.generator("Int64", MachineBits)
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-1"),
      LawSpecScalars.bounded("Int64", "-9223372036854775808", "-1")
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775800"), java.math.BigInteger("-9223372036854775795"),
      LawSpecScalars.bounded("Int64", "-9223372036854775800", "-9223372036854775795")
    ),
    RangeCase("Int64", 32, java.math.BigInteger("9223372036854775800"), java.math.BigInteger("9223372036854775806"),
      LawSpecScalars.bounded("Int64", "9223372036854775800", "9223372036854775806")
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-5000000000000000000"), java.math.BigInteger("8000000000000000000"),
      LawSpecScalars.bounded("Int64", "-5000000000000000000", "8000000000000000000")
    ),
    RangeCase("UInt64", 32, java.math.BigInteger("18446744073709551000"), java.math.BigInteger("18446744073709551615"),
      LawSpecScalars.bounded("UInt64", "18446744073709551000", "18446744073709551615")
    ),
    RangeCase("UInt64", 32, java.math.BigInteger("0"), java.math.BigInteger("18446744073709551615"),
      LawSpecScalars.generator("UInt64", MachineBits)
    ),
    RangeCase("Integer", 32, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      LawSpecScalars.bounded(
        "Integer",
        "1267650600228229401496703205393",
        "1267650600228229401496703205397"
      )
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      LawSpecScalars.bounded(
        "Integer",
        "-1267650600228229401496703205397",
        "-1267650600228229401496703205393"
      )
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      LawSpecScalars.bounded(
        "Integer",
        "-1267650600228229401496703205376",
        "1267650600228229401496703205376"
      )
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      LawSpecScalars.bounded("Int64", "-9223372036854775808", "-9223372036854775808")
    ),
    RangeCase("IntSize", 32, java.math.BigInteger("1"), java.math.BigInteger("2147483647"),
      LawSpecScalars.small("IntSize", 1 to 2147483647)
    ),
    RangeCase("Int64", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.bounded("Int64", "1", "9223372036854775807")
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.generator("Int64", MachineBits)
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-1"),
      LawSpecScalars.bounded("Int64", "-9223372036854775808", "-1")
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775800"), java.math.BigInteger("-9223372036854775795"),
      LawSpecScalars.bounded("Int64", "-9223372036854775800", "-9223372036854775795")
    ),
    RangeCase("Int64", 64, java.math.BigInteger("9223372036854775800"), java.math.BigInteger("9223372036854775806"),
      LawSpecScalars.bounded("Int64", "9223372036854775800", "9223372036854775806")
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-5000000000000000000"), java.math.BigInteger("8000000000000000000"),
      LawSpecScalars.bounded("Int64", "-5000000000000000000", "8000000000000000000")
    ),
    RangeCase("UInt64", 64, java.math.BigInteger("18446744073709551000"), java.math.BigInteger("18446744073709551615"),
      LawSpecScalars.bounded("UInt64", "18446744073709551000", "18446744073709551615")
    ),
    RangeCase("UInt64", 64, java.math.BigInteger("0"), java.math.BigInteger("18446744073709551615"),
      LawSpecScalars.generator("UInt64", MachineBits)
    ),
    RangeCase("Integer", 64, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      LawSpecScalars.bounded(
        "Integer",
        "1267650600228229401496703205393",
        "1267650600228229401496703205397"
      )
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      LawSpecScalars.bounded(
        "Integer",
        "-1267650600228229401496703205397",
        "-1267650600228229401496703205393"
      )
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      LawSpecScalars.bounded(
        "Integer",
        "-1267650600228229401496703205376",
        "1267650600228229401496703205376"
      )
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      LawSpecScalars.bounded("Int64", "-9223372036854775808", "-9223372036854775808")
    ),
    RangeCase("IntSize", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.bounded("IntSize", "1", "9223372036854775807")
    ),
  )

  for entry <- cases do
    test(s"range and shrink bounds ${entry.name}/${entry.bits}/${entry.lower}/${entry.upper}") {
      def checkValue(value: LawSpecRuntime.Value): BigInteger =
        LawSpecRuntime.validate(entry.name, value, entry.bits)
        val integer = value.data().asInstanceOf[BigInteger]
        assert(integer.compareTo(entry.lower) >= 0 && integer.compareTo(entry.upper) <= 0,
          s"outside range: $integer")
        integer
      val seen = scala.collection.mutable.Set.empty[BigInteger]
      var shrinks = 0
      for seed <- 0L until 200L do
        val tree = entry.generator.sample(Rng(seed))
        val value = checkValue(tree.value)
        seen += value
        assert(value == checkValue(entry.generator.sample(Rng(seed)).value))
        if entry.name == "Int64" && entry.lower == BigInteger.ONE.shiftLeft(63).negate() &&
          entry.upper == BigInteger.ONE.shiftLeft(63).subtract(BigInteger.ONE) then
          var leaf = tree
          var depth = 0
          while leaf.children.nonEmpty && depth < 128 do
            leaf = leaf.children.head
            depth += 1
          assert(depth < 128)
          assert(checkValue(leaf.value) == BigInteger.ZERO, "default signed shrinking must reach zero")
        var pending = List(tree)
        for _ <- 0 until 96 if pending.nonEmpty do
          val node = pending.head
          checkValue(node.value)
          val children = node.children.take(6).toList
          shrinks += children.size
          pending = children ++ pending.tail
      if entry.lower != entry.upper then
        assert(seen.size > 1, "generator only produced one value")
        assert(shrinks > 0, "generator lost its shrink tree")
    }
