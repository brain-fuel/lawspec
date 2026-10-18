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
    //@ kotlin-bounded-generators
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
