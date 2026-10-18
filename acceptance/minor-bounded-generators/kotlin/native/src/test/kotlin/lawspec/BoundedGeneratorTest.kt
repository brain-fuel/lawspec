// Generated from templates/acceptance/minor-bounded-generators/kotlin/native/src/test/kotlin/lawspec/BoundedGeneratorTest.kt by lawspec-dev generate. Do not edit.
package lawspec

import io.kotest.core.spec.style.StringSpec
import io.kotest.property.Arb
import io.kotest.property.RTree
import io.kotest.property.RandomSource
import io.kotest.property.arbitrary.*
import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime
import lawspec.testing.lawspecList

private data class RangeCase(
    val name: String, val bits: Int, val lower: BigInteger, val upper: BigInteger,
    val generator: Arb<LawSpecRuntime.Value>,
)

private fun cases(): List<RangeCase> = listOf(
    RangeCase("Int64", 32, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("9223372036854775807")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("1")).toString(),
          )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(_bytes)
              }
          _integer
      }.map { _integer ->
          LawSpecRuntime.integer("Int64", _integer.toString())
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-1"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("9223372036854775808")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-9223372036854775808")).toString(),
          )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775800"), java.math.BigInteger("-9223372036854775795"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("6")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-9223372036854775800")).toString(),
          )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("9223372036854775800"), java.math.BigInteger("9223372036854775806"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("7")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("9223372036854775800")).toString(),
          )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-5000000000000000000"), java.math.BigInteger("8000000000000000000"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("18446744073709551615"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("13000000000000000001")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-5000000000000000000")).toString(),
          )
      }
    ),
    RangeCase("UInt64", 32, java.math.BigInteger("18446744073709551000"), java.math.BigInteger("18446744073709551615"),
      lawspecList(Arb.int(0..255), 2..2).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("1023"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("616")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "UInt64",
              _offset.add(java.math.BigInteger("18446744073709551000")).toString(),
          )
      }
    ),
    RangeCase("UInt64", 32, java.math.BigInteger("0"), java.math.BigInteger("18446744073709551615"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _integer ->
          LawSpecRuntime.integer("UInt64", _integer.toString())
      }
    ),
    RangeCase("Integer", 32, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Integer",
              _offset.add(
                  java.math.BigInteger("1267650600228229401496703205393"),
              ).toString(),
          )
      }
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Integer",
              _offset.add(
                  java.math.BigInteger("-1267650600228229401496703205397"),
              ).toString(),
          )
      }
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      lawspecList(Arb.int(0..255), 13..13).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("5070602400912917605986812821503"))
      }.filter { _offset ->
          _offset.compareTo(
              java.math.BigInteger("2535301200456458802993406410753"),
          ) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Integer",
              _offset.add(
                  java.math.BigInteger("-1267650600228229401496703205376"),
              ).toString(),
          )
      }
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("0"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("1")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-9223372036854775808")).toString(),
          )
      }
    ),
    RangeCase("IntSize", 32, java.math.BigInteger("1"), java.math.BigInteger("2147483647"),
      Arb.int(1..2147483647).map { _number ->
          LawSpecRuntime.integer("IntSize", _number.toString())
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("9223372036854775807")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("1")).toString(),
          )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(_bytes)
              }
          _integer
      }.map { _integer ->
          LawSpecRuntime.integer("Int64", _integer.toString())
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-1"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("9223372036854775808")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-9223372036854775808")).toString(),
          )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775800"), java.math.BigInteger("-9223372036854775795"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("6")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-9223372036854775800")).toString(),
          )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("9223372036854775800"), java.math.BigInteger("9223372036854775806"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("7")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("9223372036854775800")).toString(),
          )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-5000000000000000000"), java.math.BigInteger("8000000000000000000"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("18446744073709551615"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("13000000000000000001")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-5000000000000000000")).toString(),
          )
      }
    ),
    RangeCase("UInt64", 64, java.math.BigInteger("18446744073709551000"), java.math.BigInteger("18446744073709551615"),
      lawspecList(Arb.int(0..255), 2..2).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("1023"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("616")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "UInt64",
              _offset.add(java.math.BigInteger("18446744073709551000")).toString(),
          )
      }
    ),
    RangeCase("UInt64", 64, java.math.BigInteger("0"), java.math.BigInteger("18446744073709551615"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _integer ->
          LawSpecRuntime.integer("UInt64", _integer.toString())
      }
    ),
    RangeCase("Integer", 64, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Integer",
              _offset.add(
                  java.math.BigInteger("1267650600228229401496703205393"),
              ).toString(),
          )
      }
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("7"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("5")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Integer",
              _offset.add(
                  java.math.BigInteger("-1267650600228229401496703205397"),
              ).toString(),
          )
      }
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      lawspecList(Arb.int(0..255), 13..13).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("5070602400912917605986812821503"))
      }.filter { _offset ->
          _offset.compareTo(
              java.math.BigInteger("2535301200456458802993406410753"),
          ) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Integer",
              _offset.add(
                  java.math.BigInteger("-1267650600228229401496703205376"),
              ).toString(),
          )
      }
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      lawspecList(Arb.int(0..255), 1..1).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("0"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("1")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "Int64",
              _offset.add(java.math.BigInteger("-9223372036854775808")).toString(),
          )
      }
    ),
    RangeCase("IntSize", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      lawspecList(Arb.int(0..255), 8..8).map { _raw ->
          val _bytes = _raw.map { it.toByte() }.toByteArray()
          val _integer =
              if (_bytes.isEmpty()) {
                  java.math.BigInteger.ZERO
              } else {
                  java.math.BigInteger(1, _bytes)
              }
          _integer
      }.map { _rawInteger ->
          _rawInteger.and(java.math.BigInteger("9223372036854775807"))
      }.filter { _offset ->
          _offset.compareTo(java.math.BigInteger("9223372036854775807")) < 0
      }.map { _offset ->
          LawSpecRuntime.integer(
              "IntSize",
              _offset.add(java.math.BigInteger("1")).toString(),
          )
      }
    ),
)

class BoundedGeneratorTest : StringSpec({
    for (case in cases()) {
        "range and shrink bounds ${case.name}/${case.bits}/${case.lower}/${case.upper}" {
            fun checkValue(value: LawSpecRuntime.Value): BigInteger {
                LawSpecRuntime.validate(case.name, value, case.bits)
                val integer = value.data() as BigInteger
                check(integer >= case.lower && integer <= case.upper) { "outside range: $integer" }
                return integer
            }
            val seen = mutableSetOf<BigInteger>()
            var shrinks = 0
            for (seed in 0L until 200L) {
                val sample = case.generator.sample(RandomSource.seeded(seed))
                val value = checkValue(sample.value)
                seen.add(value)
                check(value == checkValue(case.generator.sample(RandomSource.seeded(seed)).value))
                if (case.name == "Int64" && case.lower == BigInteger.ONE.shiftLeft(63).negate() &&
                    case.upper == BigInteger.ONE.shiftLeft(63).subtract(BigInteger.ONE)) {
                    var leaf = sample.shrinks
                    var depth = 0
                    while (leaf.children.value.isNotEmpty() && depth < 128) {
                        leaf = leaf.children.value.first()
                        depth++
                    }
                    check(depth < 128)
                    check(checkValue(leaf.value()) == BigInteger.ZERO) { "default signed shrinking must reach zero" }
                }
                val pending = ArrayDeque<RTree<LawSpecRuntime.Value>>()
                pending.add(sample.shrinks)
                repeat(96) {
                    if (pending.isNotEmpty()) {
                        val node = pending.removeLast()
                        checkValue(node.value())
                        val children = node.children.value.take(6)
                        shrinks += children.size
                        pending.addAll(children.reversed())
                    }
                }
            }
            if (case.lower != case.upper) {
                check(seen.size > 1) { "generator only produced one value" }
                check(shrinks > 0) { "generator lost its shrink tree" }
            }
        }
    }
})
