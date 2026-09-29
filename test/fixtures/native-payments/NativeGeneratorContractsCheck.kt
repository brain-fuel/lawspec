package domain

import io.kotest.property.RandomSource
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecRuntime.Data
import lawspec.runtime.LawSpecSchema.Named
import lawspec.testing.LawSpecKotlinStrategies
import lawspec.testing.LawSpecNativeGenerators
import java.math.BigDecimal

fun checkNativeGenerators(bits: Int) {
    val generator = LawSpecKotlinStrategies.checkedGenerator(
        LawSpecDataSchema.create(), Named("example.payments::type::Money"), bits,
        64, 10, mutableMapOf(), emptyList(), LawSpecNativeGenerators.factories(),
    ) { error("Money's native factory supplies all its fields") }
    var tree = generator.sample(RandomSource.seeded(811)).shrinks
    fun amount(value: LawSpecKotlinStrategies.Checked): BigDecimal =
        ((value.requireValue().data() as Data).fields()[0].data() as BigDecimal)
    val initial = amount(tree.value())
    var steps = 0
    while (true) {
        val next = tree.children.value.firstOrNull { amount(it.value()) < amount(tree.value()) } ?: break
        tree = next
        check(++steps < 100)
    }
    check(amount(tree.value()).compareTo(BigDecimal("1.00")) == 0)
    check(initial > amount(tree.value()) && steps > 0)
    println("Emitted Kotlin Money factory shrank $initial to 1.00")
}
