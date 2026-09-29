package lawspec.testing

import io.kotest.property.Arb
import io.kotest.property.RTree
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

    fun interface NativeFactory {
        fun create(
            schema: LawSpecSchema,
            type: Named,
            bits: Int,
            symbols: MutableMap<String, Any>,
            arguments: List<Arb<Value>>,
        ): Arb<Value>
    }

    private class NativeFailure(type: Named, cause: RuntimeException) :
        IllegalArgumentException(
            "native generator ${LawSpecSchema.key(type)}: ${cause.message}", cause,
        )

    fun <T> nativeValues(codec: LawSpecSchema.Codec<T>, source: Arb<T>): Arb<Value> =
        source.map { value ->
            try {
                codec.encode(value)
            } catch (error: RuntimeException) {
                throw NativeFailure(codec.type(), error)
            }
        }

    fun <T> nativeArguments(codec: LawSpecSchema.Codec<T>, source: Arb<Value>): Arb<T> =
        source.map { value ->
            try {
                codec.decode(value)
            } catch (error: RuntimeException) {
                throw NativeFailure(codec.type(), error)
            }
        }

    // Retain the native tree, including failures encountered while evaluating a
    // shrink node or enumerating its children. Report those in property callbacks.
    private fun capture(source: Arb<Checked>): Arb<Checked> = object : Arb<Checked>() {
        override fun edgecase(rs: RandomSource): Checked? = null

        fun failure(error: NativeFailure) = RTree({ Checked(null, error) })

        fun tree(source: RTree<Checked>): RTree<Checked> {
            val value = try {
                source.value()
            } catch (error: NativeFailure) {
                return failure(error)
            }
            return RTree({ value }, lazy {
                try {
                    source.children.value.map(::tree)
                } catch (error: NativeFailure) {
                    listOf(failure(error))
                }
            })
        }

        override fun sample(rs: RandomSource): Sample<Checked> {
            val result = try {
                tree(source.sample(rs).shrinks)
            } catch (error: NativeFailure) {
                failure(error)
            }
            return Sample(result.value(), result)
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
    ): Arb<Checked> = checkedGenerator(
        schema, type, bits, budget, maxAttempts, symbols, witnesses, emptyMap(), scalar,
    )

    fun checkedGenerator(
        schema: LawSpecSchema,
        type: Named,
        bits: Int,
        budget: Int,
        maxAttempts: Int,
        symbols: MutableMap<String, Any>,
        witnesses: List<Value>,
        factories: Map<String, NativeFactory>,
        scalar: (String) -> Arb<Value>,
    ): Arb<Checked> {
        require(budget > 0) { "structural node budget must be positive" }
        require(bits == 32 || bits == 64) { "machineBits must be 32 or 64" }
        require(maxAttempts > 0) { "maxAttempts must be positive" }
        schema.isScalar(type)
        val builder = Builder(schema, bits, scalar, symbols, maxAttempts, factories)
        witnesses.forEach { builder.addWitness(type, schema.validate(type, it, bits, symbols)) }
        val source = requireNotNull(builder.build(type, budget)) {
            "no value of ${LawSpecSchema.key(type)} within structural node budget $budget"
        }
        return capture(source.map { value ->
            try {
                Checked(schema.validate(type, value, bits, symbols), null)
            } catch (error: RuntimeException) {
                Checked(null, error)
            }
        })
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

    /**
     * Values whose linear structural measure equals [target]. Each constructor's equation holds
     * its constant followed by the positions of recursive fields whose measures it adds, so the
     * target is solved backwards and split across those fields. Nothing is filtered away.
     */
    fun indexedGenerator(
        schema: LawSpecSchema,
        type: Named,
        bits: Int,
        budget: Int,
        symbols: MutableMap<String, Any>,
        target: Any,
        equations: Map<String, LongArray>,
        scalar: (String) -> Arb<Value>,
    ): Arb<Checked> {
        val k = when (target) {
            is Value -> (target.data() as Number).toLong()
            is Number -> target.toLong()
            else -> throw IllegalArgumentException("index target must be a natural number")
        }
        require(k >= 0) { "index target must be a natural number" }
        require(!schema.isScalar(type)) { "indexed generation requires a data type" }
        val source = Indexed(schema, bits, budget, equations, Builder(schema, bits, scalar))
            .generate(type, k)
        return capture(source.map { value ->
            try {
                Checked(schema.validate(type, value, bits, symbols), null)
            } catch (error: RuntimeException) {
                Checked(null, error)
            }
        })
    }

    private class Indexed(
        val schema: LawSpecSchema,
        val bits: Int,
        val budget: Int,
        val equations: Map<String, LongArray>,
        val builder: Builder,
    ) {
        val reachable = mutableMapOf<Pair<Named, Long>, Boolean>()
        val visiting = mutableSetOf<Pair<Named, Long>>()
        val cache = mutableMapOf<Pair<Named, Long>, Arb<Value>>()

        fun equation(tag: String): LongArray =
            requireNotNull(equations[tag]) { "missing index equation for $tag" }

        fun positions(equation: LongArray): List<Int> =
            (1 until equation.size).map { equation[it].toInt() }

        fun indexTypes(type: Named, tag: String): List<Named> {
            val fields = schema.fields(type, tag)
            return positions(equation(tag)).map { fields[it].type() as Named }
        }

        fun feasible(type: Named, tag: String, k: Long): Boolean {
            val equation = equation(tag)
            val rest = k - equation[0]
            val fields = schema.fields(type, tag)
            val positions = positions(equation)
            if (rest < 0) return false
            val plain = fields.indices.all {
                it in positions || builder.build(fields[it].type() as Named, budget) != null
            }
            if (!plain) return false
            val types = indexTypes(type, tag)
            return if (types.isEmpty()) rest == 0L else splittable(types, rest)
        }

        fun reachable(type: Named, k: Long): Boolean {
            val key = type to k
            reachable[key]?.let { return it }
            if (!visiting.add(key)) return false
            val result = schema.constructors(type).any { feasible(type, it, k) }
            visiting.remove(key)
            reachable[key] = result
            return result
        }

        fun splittable(types: List<Named>, rest: Long): Boolean =
            if (types.size == 1) {
                reachable(types[0], rest)
            } else {
                (0..rest).any { reachable(types[0], it) && splittable(types.drop(1), rest - it) }
            }

        // Splits are chosen from the feasible values, which shrink toward the first.
        fun splits(types: List<Named>, rest: Long): Arb<List<Long>> {
            if (types.isEmpty()) return Arb.constant(emptyList())
            if (types.size == 1) return Arb.constant(listOf(rest))
            val choices = (0..rest).filter {
                reachable(types[0], it) && splittable(types.drop(1), rest - it)
            }
            return lawspecFlatMap(Arb.int(choices.indices)) { index ->
                splits(types.drop(1), rest - choices[index]).map { listOf(choices[index]) + it }
            }
        }

        fun generate(type: Named, k: Long): Arb<Value> {
            cache[type to k]?.let { return it }
            val variants = schema.constructors(type).filter { feasible(type, it, k) }.map { tag ->
                val fields = schema.fields(type, tag)
                val equation = equation(tag)
                val positions = positions(equation)
                lawspecFlatMap(splits(indexTypes(type, tag), k - equation[0])) { targets ->
                    val children = fields.mapIndexed { index, field ->
                        val position = positions.indexOf(index)
                        if (position >= 0) {
                            generate(field.type() as Named, targets[position])
                        } else {
                            requireNotNull(builder.build(field.type() as Named, budget))
                        }
                    }
                    children.fold(Arb.constant(emptyList<Value>())) { prior, child ->
                        Arb.bind(prior, child) { values, value -> values + value }
                    }.map { schema.construct(type, tag, it, bits) }
                }
            }
            require(variants.isNotEmpty()) {
                "no value of ${LawSpecSchema.key(type)} has index $k"
            }
            val result = if (variants.size == 1) {
                variants[0]
            } else {
                lawspecFlatMap(Arb.int(variants.indices)) { variants[it] }
            }
            cache[type to k] = result
            return result
        }
    }

    private data class Request(val type: Named, val budget: Int)

    private class Builder(
        val schema: LawSpecSchema,
        val bits: Int,
        val scalar: (String) -> Arb<Value>,
        val symbols: MutableMap<String, Any>? = null,
        val maxAttempts: Int = 100,
        val factories: Map<String, NativeFactory> = emptyMap(),
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
            factories[type.name()]?.let { factory ->
                val arguments = type.arguments().map {
                    build(it as Named, available) ?: object : Arb<Value>() {
                        // A phantom parameter can be uninhabited. Fail only if
                        // its factory actually asks this arbitrary for a value.
                        override fun edgecase(rs: RandomSource): Value? = null
                        override fun sample(rs: RandomSource): Sample<Value> =
                            error("no native generator argument for ${LawSpecSchema.key(it)} within node budget $available")
                    }
                }
                val context = requireNotNull(symbols)
                val result = factory.create(schema, type, bits, context, arguments).map { value ->
                    try {
                        schema.validate(type, value, bits, context)
                    } catch (error: RuntimeException) {
                        throw NativeFailure(type, error)
                    }
                }
                cache[request] = result
                return result
            }
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
