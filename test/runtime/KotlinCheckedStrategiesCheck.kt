import io.kotest.property.Arb
import io.kotest.property.RTree
import io.kotest.property.RandomSource
import io.kotest.property.Sample
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecRuntime.Value
import lawspec.runtime.LawSpecSchema
import lawspec.runtime.LawSpecSchema.Constructor
import lawspec.runtime.LawSpecSchema.Definition
import lawspec.runtime.LawSpecSchema.Field
import lawspec.runtime.LawSpecSchema.Named
import lawspec.testing.LawSpecKotlinStrategies as Strategies

private fun integer(n: Int) = Runtime.integer("Int8", n.toString())

fun main(args: Array<String>) {
    val bits = args[0].toInt()
    val symbols = mutableMapOf<String, Any>()
    val contexts = Strategies.cases()
    val firstCase = contexts.sample(RandomSource.seeded(1))
    check(firstCase.value.symbols === firstCase.shrinks.value().symbols)
    check(firstCase.value.symbols !== contexts.sample(RandomSource.seeded(1)).value.symbols)
    val marker = IllegalArgumentException("case evaluation failed")
    val failedCase = Strategies.Case(emptyList(), symbols, marker)
    val filtered = Strategies.filterCases(Arb.constant(failedCase), 1) {
        error("guard evaluated after generation failure")
    }.sample(RandomSource.seeded(1)).value
    try {
        filtered.requireValues()
        error("generation error ignored")
    } catch (expected: IllegalArgumentException) {
        check(expected === marker)
    }
    val positive = Named("Positive")
    val schema = LawSpecSchema(listOf(Definition("Positive", 0, listOf(
        Constructor("Positive", listOf(Field("n", Named("Int8"))), listOf(
            LawSpecSchema.FieldPredicate { _, _, fields, _, _ ->
                (fields[0].data() as BigInteger).signum() > 0
            },
        )),
    ))))
    val list = Named("List", positive)
    val witness = Value("List Positive", listOf(
        Value("Positive", Runtime.Data("Positive", listOf(integer(1)))),
    ))
    val generator = Strategies.checkedGenerator(schema, list, bits, 24, 100, symbols,
        listOf(witness)) { Arb.int(-5..20).map(::integer) }
    val samples = (1L..60L).map { generator.sample(RandomSource.seeded(it)).shrinks }
    fun valid(tree: RTree<Strategies.Checked>) {
        schema.validate(list, tree.value().requireValue(), bits, symbols)
    }
    samples.forEach { tree ->
        valid(tree)
        tree.children.value.forEach(::valid)
    }
    fun length(tree: RTree<Strategies.Checked>) =
        (tree.value().requireValue().data() as List<*>).size
    var shrinking = samples.first { length(it) >= 5 }
    val original = length(shrinking)
    var steps = 0
    while (true) {
        check(steps++ < 500)
        val children = shrinking.children.value
        children.forEach(::valid)
        shrinking = children.firstOrNull { length(it) >= 5 } ?: break
    }
    check(length(shrinking) in 5..original)
    check(steps > 1)
    val seeded = Strategies.checkedGenerator(schema, list, bits, 24, 100, symbols,
        listOf(witness)) { Arb.constant(integer(0)) }
    check((1L..40L).any {
        (seeded.sample(RandomSource.seeded(it)).value.requireValue().data() as List<*>).size > 1
    })
    var draws = 0
    val empty = Strategies.checkedGenerator(schema, positive, bits, 4, 3, symbols,
        emptyList()) {
        object : Arb<Value>() {
            override fun edgecase(rs: RandomSource): Value? = null
            override fun sample(rs: RandomSource): Sample<Value> {
                draws++
                return Sample(integer(0))
            }
        }
    }
    try {
        empty.sample(RandomSource.seeded(1))
        error("invalid domain generated")
    } catch (expected: IllegalArgumentException) {
        check(expected.message!!.contains("exhausted 3 attempts"))
        check(draws == 3)
    }
    val broken = LawSpecSchema(listOf(Definition("Broken", 0, listOf(
        Constructor("Broken", listOf(Field("n", Named("Int8"))), listOf(
            LawSpecSchema.FieldPredicate { _, _, _, _, _ -> error("predicate exploded") },
        )),
    ))))
    val errors = Strategies.checkedGenerator(broken, Named("Broken"), bits, 4, 3, symbols,
        emptyList()) { Arb.constant(integer(1)) }
    val failure = errors.sample(RandomSource.seeded(1)).value.error
    check(failure != null && failure.message!!.contains("predicate exploded"))
    check(!failure.message!!.contains("exhausted"))
    val shrinkSchema = LawSpecSchema(listOf(Definition("ShrinkError", 0, listOf(
        Constructor("ShrinkError", listOf(Field("n", Named("Int8"))), listOf(
            LawSpecSchema.FieldPredicate { _, _, fields, _, _ ->
                if (fields[0].data() == BigInteger.ONE) error("shrink predicate exploded")
                true
            },
        )),
    ))))
    val shrinkErrors = Strategies.checkedGenerator(shrinkSchema, Named("ShrinkError"), bits,
        4, 3, symbols, emptyList()) {
        object : Arb<Value>() {
            override fun edgecase(rs: RandomSource): Value? = null
            override fun sample(rs: RandomSource): Sample<Value> {
                val tree = RTree({ integer(2) }, lazy { listOf(RTree({ integer(1) })) })
                return Sample(tree.value(), tree)
            }
        }
    }.sample(RandomSource.seeded(1))
    check(shrinkErrors.value.error == null)
    check(shrinkErrors.shrinks.children.value.any {
        it.value().error?.message?.contains("shrink predicate exploded") == true
    })
    val identity = Named("Identity")
    val identitySchema = LawSpecSchema(listOf(Definition("Identity", 0, listOf(
        Constructor("Identity", listOf(Field("s", Named("Symbol"))), listOf(
            LawSpecSchema.FieldPredicate { _, _, fields, _, context ->
                Runtime.equal(fields[0], Runtime.symbol("fixture", "same", context))
            },
        )),
    ))))
    val token = Runtime.symbol("fixture", "same", symbols)
    val identities = Strategies.checkedGenerator(identitySchema, identity, bits, 4, 3, symbols,
        emptyList()) { Arb.constant(token) }
    identitySchema.validate(identity,
        identities.sample(RandomSource.seeded(1)).value.requireValue(), bits, symbols)
    try {
        Strategies.checkedGenerator(schema, positive, bits, 4, 3, symbols,
            listOf(Value("Positive", Runtime.Data("Positive", listOf(integer(0)))))) {
            Arb.constant(integer(1))
        }
        error("invalid witness accepted")
    } catch (_: LawSpecSchema.RefinementViolation) {
        // Witnesses must satisfy their complete instantiated type.
    }
    try {
        Strategies.generator(schema, positive, bits, 4) { Arb.constant(integer(1)) }
        error("legacy strategy accepted contracts")
    } catch (expected: IllegalArgumentException) {
        check(expected.message!!.contains("checked generation"))
    }
    println("Kotlin checked strategies and shrinking pass: $bits")
}
