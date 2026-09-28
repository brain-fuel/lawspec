package lawspec.testing

import io.kotest.property.Arb
import io.kotest.property.RandomSource
import io.kotest.property.Sample
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import io.kotest.property.filter
import lawspec.runtime.LawSpecRuntime.Data
import lawspec.runtime.LawSpecRuntime.Presence
import lawspec.runtime.LawSpecRuntime.Value
import lawspec.runtime.LawSpecSchema
import lawspec.runtime.LawSpecSchema.Named

/** Native Kotest generation and shrinking for instantiated Core data schemas. */
object LawSpecKotlinStrategies {
    fun generator(
        schema: LawSpecSchema,
        type: Named,
        bits: Int,
        budget: Int,
        scalar: (String) -> Arb<Value>,
    ): Arb<Value> {
        require(!schema.hasContracts()) { "constructor contracts require checked generation" }
        require(budget > 0) { "structural node budget must be positive" }
        require(bits == 32 || bits == 64) { "machineBits must be 32 or 64" }
        schema.isScalar(type) // Validate the entire type application before planning.
        return requireNotNull(Builder(schema, bits, scalar).build(type, budget)) {
            "no value of ${LawSpecSchema.key(type)} within structural node budget $budget"
        }
    }

    data class Case(
        val values: List<Value>,
        val symbols: MutableMap<String, Any>,
        val error: RuntimeException? = null,
    ) {
        fun requireValues(): List<Value> {
            error?.let { throw it }
            return values
        }
    }

    fun cases(): Arb<Case> = object : Arb<Case>() {
        override fun edgecase(rs: RandomSource): Case? = null

        override fun sample(rs: RandomSource): Sample<Case> =
            Sample(Case(emptyList(), mutableMapOf()))
    }

    fun filterCases(source: Arb<Case>, attempts: Int, predicate: (Case) -> Boolean): Arb<Case> {
        require(attempts > 0) { "maxAttempts must be positive" }
        return bounded(source, attempts, "property inputs") { it.error != null || predicate(it) }
    }

    data class Checked(val value: Value?, val error: RuntimeException?) {
        fun requireValue(): Value {
            error?.let { throw it }
            return requireNotNull(value)
        }
    }

    fun checkedGenerator(
        schema: LawSpecSchema,
        type: Named,
        bits: Int,
        budget: Int,
        maxAttempts: Int,
        symbols: MutableMap<String, Any>,
        witnesses: List<Value>,
        scalar: (String) -> Arb<Value>,
    ): Arb<Checked> {
        require(budget > 0) { "structural node budget must be positive" }
        require(bits == 32 || bits == 64) { "machineBits must be 32 or 64" }
        require(maxAttempts > 0) { "maxAttempts must be positive" }
        schema.isScalar(type)
        val builder = Builder(schema, bits, scalar, symbols, maxAttempts)
        witnesses.forEach { builder.addWitness(type, schema.validate(type, it, bits, symbols)) }
        val source = requireNotNull(builder.build(type, budget)) {
            "no value of ${LawSpecSchema.key(type)} within structural node budget $budget"
        }
        return source.map { value ->
            try {
                Checked(schema.validate(type, value, bits, symbols), null)
            } catch (error: RuntimeException) {
                Checked(null, error)
            }
        }
    }

    private fun nodes(value: Value): Int = 1 + when (val data = value.data()) {
        is Data -> data.fields().sumOf(::nodes)
        is Presence -> if (data.present()) nodes(data.value()) else 0
        is List<*> -> {
            if (value.type().startsWith("List ")) {
                data.sumOf { nodes(it as Value) }
            } else {
                0
            }
        }
        else -> 0
    }

    private fun <T> bounded(
        source: Arb<T>,
        attempts: Int,
        label: String,
        accepted: (T) -> Boolean,
    ): Arb<T> = object : Arb<T>() {
        override fun edgecase(rs: RandomSource): T? = null

        override fun sample(rs: RandomSource): Sample<T> {
            repeat(attempts) {
                val sample = source.sample(rs)
                val tree = sample.shrinks.filter(accepted)
                if (tree != null) return Sample(tree.value(), tree)
            }
            throw IllegalArgumentException(
                "constructor generation exhausted $attempts attempts for $label",
            )
        }
    }

    private data class Request(val type: Named, val budget: Int)

    private class Builder(
        val schema: LawSpecSchema,
        val bits: Int,
        val scalar: (String) -> Arb<Value>,
        val symbols: MutableMap<String, Any>? = null,
        val maxAttempts: Int = 100,
    ) {
        val witnesses = mutableMapOf<Named, MutableList<Value>>()
        val cache = mutableMapOf<Request, Arb<Value>?>()

        fun addWitness(type: Named, value: Value) {
            witnesses.getOrPut(type) { mutableListOf() }.add(value)
            when {
                schema.isScalar(type) -> Unit
                type.name() == "List" -> {
                    (value.data() as List<*>).forEach {
                        addWitness(type.arguments()[0] as Named, it as Value)
                    }
                }
                type.name() in listOf("Nullable", "Optional") -> {
                    val presence = value.data() as Presence
                    if (presence.present()) {
                        addWitness(type.arguments()[0] as Named, presence.value())
                    }
                }
                else -> {
                    val data = value.data() as Data
                    schema.fields(type, data.tag()).forEachIndexed { index, field ->
                        addWitness(field.type() as Named, data.fields()[index])
                    }
                }
            }
        }

        fun minimum(type: Named, limit: Int): Int? =
          (1..limit).firstOrNull { build(type, it) != null }

        fun allocation(fields: List<LawSpecSchema.Field>, available: Int): List<Int>? {
            var remaining = available
            val minima = fields.map { field ->
                val cost = minimum(field.type() as Named, remaining) ?: return null
                remaining -= cost
                cost
            }
            return minima.mapIndexed { index, cost ->
                cost + remaining / minima.size + if (index < remaining % minima.size) 1 else 0
            }
        }

        fun build(type: Named, available: Int): Arb<Value>? {
            if (available < 1) return null
            val request = Request(type, available)
            if (cache.containsKey(request)) return cache[request]
            var result = when {
                schema.isScalar(type) -> scalar(type.name()).map { schema.validate(type, it, bits) }
                type.name() == "List" -> list(type, available)
                type.name() in listOf("Nullable", "Optional") -> presence(type, available)
                else -> {
                    choice(schema.constructors(type).mapNotNull { tag ->
                        val fields = schema.fields(type, tag)
                        val costs = allocation(fields, available - 1) ?: return@mapNotNull null
                        val children = fields.mapIndexed { index, field ->
                            requireNotNull(build(field.type() as Named, costs[index]))
                        }
                        val product =
                            children.fold(Arb.constant(emptyList<Value>())) { prior, child ->
                                Arb.bind(prior, child) { values, value -> values + value }
                            }
                        product.map {
                            if (symbols == null) {
                                schema.construct(type, tag, it, bits)
                            } else {
                                Value(LawSpecSchema.key(type), Data(tag, it))
                            }
                        }
                    })
                }
            }
            if (result != null && symbols != null) {
                val seeds = witnesses[type].orEmpty().filter { nodes(it) <= available }
                if (seeds.isNotEmpty()) {
                    val sample = Arb.int(seeds.indices).map { seeds[it] }
                    result = lawspecChoice(result, sample)
                }
                result = bounded(result, maxAttempts, LawSpecSchema.key(type)) { value ->
                    try {
                        schema.check(type, value, bits, symbols) is LawSpecSchema.Accepted
                    } catch (error: RuntimeException) {
                        // Keep evaluator errors for the outer checked result to report.
                        true
                    }
                }
            }
            cache[request] = result
            return result
        }

        fun list(type: Named, available: Int): Arb<Value> {
            val element = type.arguments()[0] as Named
            val remaining = available - 1
            val cost = minimum(element, remaining)
            val maximum = if (cost == null) 0 else remaining / cost
            // Plan before sampling: callbacks only select immutable native arbitraries.
            val sizes = (0..maximum).map { length ->
                if (length == 0) {
                    Arb.constant(Value(LawSpecSchema.key(type), emptyList<Value>()))
                } else {
                    lawspecList(requireNotNull(build(element, remaining / length)), length..length)
                        .map { Value(LawSpecSchema.key(type), it) }
                }
            }
            return lawspecFlatMap(Arb.int(0..maximum)) { sizes[it] }
        }

        fun presence(type: Named, available: Int): Arb<Value> {
            val absent = Arb.constant(Value(LawSpecSchema.key(type), Presence(false, null)))
            val child = build(type.arguments()[0] as Named, available - 1) ?: return absent
            val present = child.map { Value(LawSpecSchema.key(type), Presence(true, it)) }
            return requireNotNull(choice(listOf(absent, present)))
        }

        fun choice(alternatives: List<Arb<Value>>): Arb<Value>? = when (alternatives.size) {
            0 -> null
            1 -> alternatives[0]
            else -> lawspecFlatMap(Arb.int(alternatives.indices)) { alternatives[it] }
        }
    }
}
