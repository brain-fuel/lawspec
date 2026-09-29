import io.kotest.property.Arb
import io.kotest.property.RTree
import io.kotest.property.RandomSource
import io.kotest.property.Sample
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import io.kotest.property.checkAll
import kotlinx.coroutines.runBlocking
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecRuntime.Value
import lawspec.runtime.LawSpecSchema
import lawspec.runtime.LawSpecSchema.Constructor
import lawspec.runtime.LawSpecSchema.Definition
import lawspec.runtime.LawSpecSchema.Field
import lawspec.runtime.LawSpecSchema.Named
import lawspec.runtime.LawSpecSchema.Parameter
import lawspec.testing.LawSpecKotlinStrategies as Strategies

private data class Wrapped<T>(val item: T)

private fun emptyParameters(bits: Int) {
    val schema = LawSpecSchema(listOf(
        Definition("Empty", 0, emptyList()),
        Definition("Phantom", 1, listOf(Constructor("Phantom", listOf(Field("value", Named("Int8")))))),
    ))
    val type = Named("Phantom", Named("Empty"))
    fun wrap(value: Int) = schema.construct(type, "Phantom", listOf(Runtime.integer("Int8", value.toString())), bits)
    fun generated(demand: Boolean) = Strategies.checkedGenerator(schema, type, bits, 32, 3,
        mutableMapOf(), emptyList(), mapOf("Phantom" to Strategies.NativeFactory { _, _, _, _, children ->
            check(children.size == 1)
            if (demand) children.single().map { wrap(40) } else Arb.int(40..100).map(::wrap)
        })) { Arb.constant(Runtime.integer(it, "1")) }
    fun number(tree: RTree<Strategies.Checked>) =
        ((tree.value().requireValue().data() as Runtime.Data).fields()[0].data() as java.math.BigInteger).intValueExact()
    val samples = (1L..50L).map { generated(false).sample(RandomSource.seeded(it)) }
    var tree = samples.first { number(it.shrinks) > 40 }.shrinks
    while (true) {
        tree = tree.children.value.firstOrNull { number(it) < number(tree) } ?: break
    }
    check(number(tree) == 40)
    val demanded = runCatching { generated(true).sample(RandomSource.seeded(1)) }.exceptionOrNull()
    check(demanded?.message.orEmpty().contains("no native generator argument for Empty"))
    val root = runCatching {
        Strategies.generator(schema, Named("Empty"), bits, 32) { Arb.constant(Runtime.integer(it, "1")) }
    }.exceptionOrNull()
    check(root?.message.orEmpty().contains("no value of Empty"))
}

fun main(args: Array<String>) = runBlocking {
    val bits = args.single().toInt()
    emptyParameters(bits)
    val schema = LawSpecSchema(listOf(
        Definition("Box", 1, listOf(Constructor("Box", listOf(Field("item", Parameter(0)))))),
        Definition("Positive", 0, listOf(Constructor("Positive", listOf(Field("n", Named("Int8"))),
            listOf(LawSpecSchema.FieldPredicate { _, _, fields, _, _ ->
                (fields[0].data() as java.math.BigInteger).signum() > 0
            }),
        ))),
    ))
    val scalar = schema.codec<Int>(Named("Int8"), bits,
        { Runtime.integer("Int8", it.toString()) },
        { (it.data() as java.math.BigInteger).intValueExact() },
    )
    val boxType = Named("Box", Named("Int8"))
    val box = schema.codec<Wrapped<Int>>(
        boxType, bits,
        { value -> schema.construct(boxType, "Box", listOf(scalar.encode(value.item)), bits) },
        { value -> Wrapped(scalar.decode((value.data() as Runtime.Data).fields()[0])) },
    )
    val symbols = mutableMapOf<String, Any>()
    fun generator(
        type: Named,
        factories: Map<String, Strategies.NativeFactory>,
        witnesses: List<Value> = emptyList(),
    ) = Strategies.checkedGenerator(schema, type, bits, 12, 3, symbols, witnesses, factories) {
        Arb.constant(Runtime.integer(it, "1"))
    }
    fun factory(source: Arb<Int>) = Strategies.NativeFactory { _, _, _, _, _ ->
        Strategies.nativeValues(scalar, source)
    }
    val bindings = mapOf(
        "Int8" to factory(Arb.int(40..100)),
        "Box" to Strategies.NativeFactory { _, _, _, _, arguments ->
            val child = Strategies.nativeArguments(scalar, arguments.single())
            Strategies.nativeValues(box, child.map { Wrapped(it) })
        },
    )
    val native = generator(boxType, bindings)
    val samples = (1L..50L).map { native.sample(RandomSource.seeded(it)) }
    fun number(tree: RTree<Strategies.Checked>) = box.decode(tree.value().requireValue()).item
    var tree = samples.first { number(it.shrinks) > 40 }.shrinks
    val initial = number(tree)
    var steps = 0
    while (true) {
        val next = tree.children.value.firstOrNull { number(it) < number(tree) } ?: break
        tree = next
        check(++steps < 100)
    }
    check(number(tree) == 40 && initial > 40 && steps > 0)

    val unchecked = generator(boxType, mapOf("Int8" to Strategies.NativeFactory { _, _, _, _, _ ->
        Arb.constant(Runtime.integer("Int8", "999"))
    })).sample(RandomSource.seeded(1)).value
    check(unchecked.error?.message.orEmpty().contains("native generator Int8"))

    val positive = Named("Positive")
    val invalidContract = Value("Positive", Runtime.Data("Positive", listOf(Runtime.integer("Int8", "0"))))
    val validWitness = Value("Positive", Runtime.Data("Positive", listOf(Runtime.integer("Int8", "1"))))
    val contractFailure = generator(positive, mapOf("Positive" to Strategies.NativeFactory { _, _, _, _, _ ->
        Arb.constant(invalidContract)
    }), listOf(validWitness)).sample(RandomSource.seeded(1)).value
    check(contractFailure.error?.message.orEmpty().contains("native generator Positive"))

    val invalid = generator(Named("Int8"), mapOf("Int8" to factory(Arb.constant(999))))
        .sample(RandomSource.seeded(1)).value
    check(invalid.error?.message.orEmpty().contains("native generator Int8"))
    val nested = generator(boxType, mapOf("Int8" to factory(Arb.constant(999))))
        .sample(RandomSource.seeded(1)).value
    check(nested.error?.message.orEmpty().contains("native generator Int8"))

    val badShrink = object : Arb<Int>() {
        override fun edgecase(rs: RandomSource): Int? = null
        override fun sample(rs: RandomSource): Sample<Int> {
            val tree = RTree({ 64 }, lazy { listOf(RTree({ 999 })) })
            return Sample(tree.value(), tree)
        }
    }
    val shrinking = generator(Named("Int8"), mapOf("Int8" to factory(badShrink)))
    val sample = shrinking.sample(RandomSource.seeded(1))
    check(sample.value.error == null)
    check(sample.shrinks.children.value.single().value().error != null)
    val nestedShrink = generator(boxType, mapOf("Int8" to factory(badShrink)))
        .sample(RandomSource.seeded(1))
    check(nestedShrink.value.error == null)
    check(nestedShrink.shrinks.children.value.any { it.value().error != null })
    var invalidReachedCallback = false
    val propertyFailure = runCatching {
        checkAll(1, shrinking) { checked ->
            if (checked.error != null) invalidReachedCallback = true
            checked.requireValue()
            error("deliberate failure to exercise native shrinking")
        }
    }.exceptionOrNull()
    check(propertyFailure != null && invalidReachedCallback)

    val noValues = object : Arb<Int>() {
        override fun edgecase(rs: RandomSource): Int? = null
        override fun sample(rs: RandomSource): Sample<Int> = error("custom generator exhausted")
    }
    val exhausted = generator(Named("Int8"), mapOf("Int8" to factory(noValues)),
        listOf(Runtime.integer("Int8", "1")))
    val error = runCatching { exhausted.sample(RandomSource.seeded(1)) }.exceptionOrNull()
    check(error?.message.orEmpty().contains("custom generator exhausted"))
    println("Kotlin native factories: generic composition, $initial -> 40 shrinking, invalid samples/shrinks and exhaustion; bits=$bits")
}
