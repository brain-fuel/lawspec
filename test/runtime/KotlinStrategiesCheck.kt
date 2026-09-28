import io.kotest.property.Arb
import io.kotest.property.RTree
import io.kotest.property.RandomSource
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecRuntime.Value
import lawspec.runtime.LawSpecSchema
import lawspec.runtime.LawSpecSchema.Named
import lawspec.testing.LawSpecKotlinStrategies
import lawspec.testing.lawspecFlatMap

private fun primitive(name: String): Arb<Value> = when (name) {
  "Int8" -> Arb.int(-128..127).map { Runtime.integer("Int8", it.toString()) }
  "Bool" -> Arb.boolean().map { Runtime.bool(it) }
  "Unit" -> Arb.constant(Runtime.absent("Unit"))
  else -> error("unexpected primitive $name")
}

private fun nodes(value: Value): Int = 1 + when (val data = value.data()) {
  is Runtime.Data -> data.fields().sumOf(::nodes)
  is List<*> -> if (value.type().startsWith("List ")) data.sumOf { nodes(it as Value) } else 0
  is Runtime.Presence -> if (data.present()) nodes(data.value()) else 0
  else -> 0
}

private fun samples(generator: Arb<Value>): List<RTree<Value>> =
  (1L..100L).map { generator.sample(RandomSource.seeded(it)).shrinks }

private fun minimize(
  original: RTree<Value>,
  validate: (Value) -> Unit,
  fails: (Value) -> Boolean,
): Value {
  var tree = original
  var steps = 0
  while (true) {
    check(steps++ < 1000) { "non-terminating shrink tree" }
    val children = tree.children.value
    children.forEach { validate(it.value()) }
    val child = children.firstOrNull { fails(it.value()) } ?: return tree.value()
    tree = child
  }
}

fun checkStrategies() {
  fun definition(name: String, fields: List<Named>) = LawSpecSchema.Definition(name, 0,
    listOf(LawSpecSchema.Constructor("$name::Make", fields.mapIndexed { i, field ->
      LawSpecSchema.Field("field$i", field)
    })))
  val definitions = listOf(definition("Deep0", emptyList())) +
    (1..5).map { definition("Deep$it", listOf(Named("Deep${it - 1}"))) } +
    definition("Uneven", listOf(Named("Deep5")) + List(9) { Named("Bool") }) +
    LawSpecSchema.Definition("Empty", 0, emptyList())
  val schema = LawSpecSchema(definitions)
  for (bits in listOf(32, 64)) {
    fun generator(type: Named, budget: Int) =
      LawSpecKotlinStrategies.generator(schema, type, bits, budget, ::primitive)
    fun validate(type: Named, budget: Int, value: Value) {
      schema.validate(type, value, bits)
      check(nodes(value) <= budget) { "invalid node budget" }
    }
    check(runCatching { generator(Named("Uneven"), 15) }.isFailure)
    for (tree in samples(generator(Named("Uneven"), 16))) {
      validate(Named("Uneven"), 16, tree.value())
      check(nodes(tree.value()) == 16)
      tree.children.value.forEach { child -> validate(Named("Uneven"), 16, child.value()) }
    }
    val list = Named("List", Named("Deep5"))
    val deep = samples(generator(list, 7))
    deep.forEach { validate(list, 7, it.value()) }
    check(deep.any { nodes(it.value()) == 7 }) { "deep singletons excluded" }
    check(runCatching { generator(Named("Empty"), 16) }.isFailure)
    for (container in listOf("List", "Maybe", "Nullable", "Optional")) {
      val type = Named(container, Named("Empty"))
      check(runCatching { generator(type, 0) }.isFailure)
      samples(generator(type, 1)).forEach { validate(type, 1, it.value()) }
    }
    val either = Named("Either", Named("Empty"), Named("Unit"))
    check(runCatching { generator(either, 1) }.isFailure)
    samples(generator(either, 2)).forEach { validate(either, 2, it.value()) }
    val units = Named("List", Named("Unit"))
    fun long(value: Value) = (value.data() as List<*>).size > 4
    val failing = samples(generator(units, 10)).first { long(it.value()) }
    val minimal = minimize(failing, { validate(units, 10, it) }, ::long)
    check(nodes(minimal) == 6) { "length did not shrink to five" }

    val dataSchema = LawSpecDataSchema.create()
    val treeType = Named("Tree", Named("Int8"))
    val trees = LawSpecKotlinStrategies.generator(dataSchema, treeType, bits, 24, ::primitive)
    fun validTree(value: Value) {
      dataSchema.validate(treeType, value, bits)
      check(nodes(value) <= 24)
    }
    fun positive(value: Value): Boolean {
      val data = value.data() as Runtime.Data
      return if (data.tag() == "ctor::Leaf") Runtime.truth(Runtime.binary(">", data.fields()[0], Runtime.integer("Int8", "0")))
      else (data.fields()[0].data() as List<*>).any { positive(it as Value) }
    }
    val generated = samples(trees)
    generated.forEach { validTree(it.value()) }
    val positiveLeaf = generated.first {
      (it.value().data() as Runtime.Data).tag() == "ctor::Leaf" && positive(it.value())
    }
    val smallest = minimize(positiveLeaf, ::validTree, ::positive)
    val payload = smallest.data() as Runtime.Data
    check(payload.tag() == "ctor::Leaf" && payload.fields()[0].data().toString() == "1")
    // Exercise constructor-choice shrinking from a Branch to the earlier Leaf.
    val branch = generated.first { (it.value().data() as Runtime.Data).tag() == "ctor::Branch" }
    val candidates = branch.children.value.map { it.value() }
    candidates.forEach(::validTree)
    check(candidates.any { (it.data() as Runtime.Data).tag() == "ctor::Leaf" })
  }
  // A dependent arbitrary must retain its source's native shrinking.
  val dependent = lawspecFlatMap(Arb.int(0..10)) { index ->
    Arb.constant(Runtime.integer("Int8", index.toString()))
  }
  val initial = samples(dependent).first { it.value().data().toString().toInt() > 0 }
  val smallest = minimize(initial, { Runtime.validate("Int8", it, 64) }) {
    it.data().toString().toInt() > 0
  }
  check(smallest.data().toString() == "1")
  println("Kotlin native generation, budgets, and shrink trees passed")
}
