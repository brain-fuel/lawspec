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
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("9223372036854775807")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("1")).toString,
        )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          _bytes,
        )
        _integer
      }.map { _integer =>
        LawSpecRuntime.integer("Int64", _integer.toString)
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-1"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("9223372036854775808")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-9223372036854775808")).toString,
        )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775800"), java.math.BigInteger("-9223372036854775795"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("6")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-9223372036854775800")).toString,
        )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("9223372036854775800"), java.math.BigInteger("9223372036854775806"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("7")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("9223372036854775800")).toString,
        )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-5000000000000000000"), java.math.BigInteger("8000000000000000000"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("18446744073709551615"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("13000000000000000001")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-5000000000000000000")).toString,
        )
      }
    ),
    RangeCase("UInt64", 32, java.math.BigInteger("18446744073709551000"), java.math.BigInteger("18446744073709551615"),
      Arb.list(Arb.int(0 to 255), 2 to 2).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("1023"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("616")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "UInt64",
          _offset.add(java.math.BigInteger("18446744073709551000")).toString,
        )
      }
    ),
    RangeCase("UInt64", 32, java.math.BigInteger("0"), java.math.BigInteger("18446744073709551615"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _integer =>
        LawSpecRuntime.integer("UInt64", _integer.toString)
      }
    ),
    RangeCase("Integer", 32, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Integer",
          _offset.add(
            java.math.BigInteger("1267650600228229401496703205393"),
          ).toString,
        )
      }
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Integer",
          _offset.add(
            java.math.BigInteger("-1267650600228229401496703205397"),
          ).toString,
        )
      }
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      Arb.list(Arb.int(0 to 255), 13 to 13).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("5070602400912917605986812821503"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("2535301200456458802993406410753")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Integer",
          _offset.add(
            java.math.BigInteger("-1267650600228229401496703205376"),
          ).toString,
        )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("0"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("1")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-9223372036854775808")).toString,
        )
      }
    ),
    RangeCase("IntSize", 32, java.math.BigInteger("1"), java.math.BigInteger("2147483647"),
      Arb.int(1 to 2147483647).map { _number =>
        LawSpecRuntime.integer("IntSize", _number.toString)
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("9223372036854775807")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("1")).toString,
        )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          _bytes,
        )
        _integer
      }.map { _integer =>
        LawSpecRuntime.integer("Int64", _integer.toString)
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-1"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("9223372036854775808")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-9223372036854775808")).toString,
        )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775800"), java.math.BigInteger("-9223372036854775795"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("6")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-9223372036854775800")).toString,
        )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("9223372036854775800"), java.math.BigInteger("9223372036854775806"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("7")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("9223372036854775800")).toString,
        )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-5000000000000000000"), java.math.BigInteger("8000000000000000000"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("18446744073709551615"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("13000000000000000001")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-5000000000000000000")).toString,
        )
      }
    ),
    RangeCase("UInt64", 64, java.math.BigInteger("18446744073709551000"), java.math.BigInteger("18446744073709551615"),
      Arb.list(Arb.int(0 to 255), 2 to 2).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("1023"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("616")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "UInt64",
          _offset.add(java.math.BigInteger("18446744073709551000")).toString,
        )
      }
    ),
    RangeCase("UInt64", 64, java.math.BigInteger("0"), java.math.BigInteger("18446744073709551615"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _integer =>
        LawSpecRuntime.integer("UInt64", _integer.toString)
      }
    ),
    RangeCase("Integer", 64, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Integer",
          _offset.add(
            java.math.BigInteger("1267650600228229401496703205393"),
          ).toString,
        )
      }
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Integer",
          _offset.add(
            java.math.BigInteger("-1267650600228229401496703205397"),
          ).toString,
        )
      }
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      Arb.list(Arb.int(0 to 255), 13 to 13).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("5070602400912917605986812821503"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("2535301200456458802993406410753")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Integer",
          _offset.add(
            java.math.BigInteger("-1267650600228229401496703205376"),
          ).toString,
        )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      Arb.list(Arb.int(0 to 255), 1 to 1).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("0"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("1")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "Int64",
          _offset.add(java.math.BigInteger("-9223372036854775808")).toString,
        )
      }
    ),
    RangeCase("IntSize", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      Arb.list(Arb.int(0 to 255), 8 to 8).map { _raw =>
        val _bytes = _raw.map(_.toByte).toArray
        val _integer = if (_bytes.isEmpty) java.math.BigInteger.ZERO else java.math.BigInteger(
          1,
          _bytes,
        )
        _integer
      }.map { _rawInteger =>
        _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset =>
        _offset.compareTo(java.math.BigInteger("9223372036854775807")) < 0
      }.map { _offset =>
        LawSpecRuntime.integer(
          "IntSize",
          _offset.add(java.math.BigInteger("1")).toString,
        )
      }
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
