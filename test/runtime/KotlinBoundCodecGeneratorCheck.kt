package domain

import io.kotest.property.RandomSource
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecRuntime.Data
import lawspec.runtime.LawSpecSchema.Named
import lawspec.testing.LawSpecKotlinStrategies
import lawspec.testing.LawSpecNativeGenerators
import java.math.BigInteger

fun checkCodecGenerators(bits: Int) {
    val generator = LawSpecKotlinStrategies.checkedGenerator(
        LawSpecDataSchema.create(), Named("bound.codecs::type::Parcel", Named("Int8")), bits,
        64, 10, mutableMapOf(), emptyList(), LawSpecNativeGenerators.factories(),
    ) { error("native byte factory supplies its values") }
    fun stored(value: LawSpecKotlinStrategies.Checked): Int =
        ((value.requireValue().data() as Data).fields()[0].data() as BigInteger).intValueExact()
    var tree = (1L..100L).map { generator.sample(RandomSource.seeded(it)).shrinks }
        .first { stored(it.value()) > 1 }
    val initial = stored(tree.value())
    var steps = 0
    while (true) {
        val next = tree.children.value.firstOrNull { stored(it.value()) < stored(tree.value()) } ?: break
        tree = next
        check(++steps < 100)
    }
    check(stored(tree.value()) == 1 && steps > 0)
    println("Kotlin codec child shrinking: $initial -> 1")
}
