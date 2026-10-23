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
      LawSpecScalars.bounded("Int64", "1", "9223372036854775807")
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.generator("Int64", MACHINE_BITS)
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
      LawSpecScalars.generator("UInt64", MACHINE_BITS)
    ),
    RangeCase("Integer", 32, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      LawSpecScalars.bounded(
          "Integer",
          "1267650600228229401496703205393",
          "1267650600228229401496703205397",
      )
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      LawSpecScalars.bounded(
          "Integer",
          "-1267650600228229401496703205397",
          "-1267650600228229401496703205393",
      )
    ),
    RangeCase("Integer", 32, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      LawSpecScalars.bounded(
          "Integer",
          "-1267650600228229401496703205376",
          "1267650600228229401496703205376",
      )
    ),
    RangeCase("Int64", 32, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      LawSpecScalars.bounded("Int64", "-9223372036854775808", "-9223372036854775808")
    ),
    RangeCase("IntSize", 32, java.math.BigInteger("1"), java.math.BigInteger("2147483647"),
      LawSpecScalars.small("IntSize", 1..2147483647)
    ),
    RangeCase("Int64", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.bounded("Int64", "1", "9223372036854775807")
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.generator("Int64", MACHINE_BITS)
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
      LawSpecScalars.generator("UInt64", MACHINE_BITS)
    ),
    RangeCase("Integer", 64, java.math.BigInteger("1267650600228229401496703205393"), java.math.BigInteger("1267650600228229401496703205397"),
      LawSpecScalars.bounded(
          "Integer",
          "1267650600228229401496703205393",
          "1267650600228229401496703205397",
      )
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205397"), java.math.BigInteger("-1267650600228229401496703205393"),
      LawSpecScalars.bounded(
          "Integer",
          "-1267650600228229401496703205397",
          "-1267650600228229401496703205393",
      )
    ),
    RangeCase("Integer", 64, java.math.BigInteger("-1267650600228229401496703205376"), java.math.BigInteger("1267650600228229401496703205376"),
      LawSpecScalars.bounded(
          "Integer",
          "-1267650600228229401496703205376",
          "1267650600228229401496703205376",
      )
    ),
    RangeCase("Int64", 64, java.math.BigInteger("-9223372036854775808"), java.math.BigInteger("-9223372036854775808"),
      LawSpecScalars.bounded("Int64", "-9223372036854775808", "-9223372036854775808")
    ),
    RangeCase("IntSize", 64, java.math.BigInteger("1"), java.math.BigInteger("9223372036854775807"),
      LawSpecScalars.bounded("IntSize", "1", "9223372036854775807")
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
