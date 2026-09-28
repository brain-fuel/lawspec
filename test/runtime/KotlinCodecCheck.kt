import java.math.BigDecimal
import java.math.BigInteger
import lawspec.data.*
import lawspec.runtime.LawSpecDataCodecs as Codecs
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecKotlin as Native
import lawspec.runtime.LawSpecKotlinCodecs as Bridges
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecSchema
import lawspec.runtime.LawSpecSchema.Codec

private fun reject(context: kotlin.String, action: () -> Any?) {
  val failure = runCatching(action).exceptionOrNull()
  check(failure is IllegalArgumentException || failure is ArithmeticException) { "$context: $failure" }
  check(failure.message.orEmpty().contains(context)) { "$context: ${failure.message}" }
}

fun checkCodecs() {
  for (bits in listOf(32, 64)) {
    val schema = LawSpecDataSchema.create()
    fun <T> roundTrip(codec: Codec<T>, value: T): T {
      val logical = codec.encode(value)
      val copied = codec.decode(logical)
      check(schema.equal(codec.type(), logical, codec.encode(copied), bits))
      return copied
    }
    val byte = schema.scalar("Int8", bits, Byte::class.javaObjectType)
    val boolean = schema.scalar("Bool", bits, Boolean::class.javaObjectType)
    val tree = Codecs.treeCodec(schema, bits, byte)
    val children = mutableListOf<Tree<Byte>>(Tree.LeafCase(127), Tree.BranchCase(emptyList()))
    val original: Tree<Byte> = Tree.BranchCase(children)
    val copied = roundTrip(tree, original) as Tree.BranchCase
    children.clear()
    check(copied.children.size == 2)
    val pair = Codecs.pairCodec(schema, bits, boolean)
    val max = BigInteger("18446744073709551615")
    check((roundTrip(pair, Pair.PairCase(true, max)) as Pair.PairCase).second == max)
    reject("ctor::Pair.second") { pair.encode(Pair.PairCase(true, max + BigInteger.ONE)) }
    reject("ctor::Leaf.value") {
      val bigUInt = schema.scalar("BigUInt", bits, BigInteger::class.javaObjectType)
      Codecs.treeCodec(schema, bits, bigUInt).encode(Tree.LeafCase(BigInteger.valueOf(-1)))
    }
    val char = schema.scalar("Char", bits, kotlin.String::class.java)
    reject("ctor::Leaf.value") {
      Codecs.treeCodec(schema, bits, char).encode(Tree.LeafCase("\uD800"))
    }
    reject("ctor::Leaf.value") {
      Codecs.treeCodec(schema, bits, char).encode(Tree.LeafCase("two characters"))
    }
    roundTrip(Codecs.treeCodec(schema, bits, char), Tree.LeafCase("\uD83D\uDE00"))
    roundTrip(Codecs.leftSideCodec(schema, bits),
      LeftSide.AcrossCase(RightSide.BackCase(Runtime.Nothing())))
    roundTrip(Codecs.phantomCodec(schema, bits, byte), Phantom.TagCase())
    roundTrip(Codecs.choiceCodec(schema, bits, byte),
      Choice.ChooseCase(Runtime.Left(Runtime.Just(127.toByte()))))
    roundTrip(Codecs.choiceCodec(schema, bits, byte),
      Choice.ChooseCase(Runtime.Right(Pair.PairCase("text", max))))
    roundTrip(schema.list(schema.maybe(tree, bits), bits),
      listOf(Runtime.Nothing(), Runtime.Just(Tree.LeafCase(1.toByte()))))
    for (state in listOf<Native.Nullable<Native.Optional<Byte>>>(
      Native.Nullable.Null(), Native.Nullable.Present(Native.Optional.Undefined()),
      Native.Nullable.Present(Native.Optional.Present(127)),
    )) {
      roundTrip(Codecs.presenceCodec(schema, bits),
        Presence.StatesCase(state, Unit, Native.Null, Native.Undefined))
    }
    check(Bridges.unit(schema, bits).decode(Runtime.absent("Unit")) === Unit)
    val identity = Native.Symbol("same")
    val raw = Raw.RawCase("\uD83D\uDE00", intArrayOf(0xD800), "\uD800",
      byteArrayOf(0, -1), identity, Runtime.Ratio(BigInteger.ONE, BigInteger.TWO),
      Runtime.Complex(1.5, -0.0))
    val rawCopy = roundTrip(Codecs.rawCodec(schema, bits), raw) as Raw.RawCase
    check(rawCopy.symbol == identity && rawCopy.symbol != Native.Symbol("same"))
    check(rawCopy.points.contentEquals(raw.points) && rawCopy.points !== raw.points)
    check(rawCopy.bytes.contentEquals(raw.bytes) && rawCopy.bytes !== raw.bytes)
    check(rawCopy.units[0].code == 0xD800)
    val decimal = schema.scalar("Decimal", bits, BigDecimal::class.java)
    roundTrip(Codecs.treeCodec(schema, bits, decimal), Tree.LeafCase(BigDecimal("0.3")))
    for (name in listOf("IntSize", "UIntSize", "UIntPtr")) {
      val machine = schema.scalar(name, bits, BigInteger::class.java)
      val machineMax = BigInteger.ONE.shiftLeft(bits - if (name == "IntSize") 1 else 0) - BigInteger.ONE
      roundTrip(Codecs.treeCodec(schema, bits, machine), Tree.LeafCase(machineMax))
      reject("ctor::Leaf.value") {
        Codecs.treeCodec(schema, bits, machine).encode(Tree.LeafCase(machineMax + BigInteger.ONE))
      }
    }
    val codeUnit = schema.scalar("CodeUnit16", bits, Char::class.javaObjectType)
    roundTrip(Codecs.treeCodec(schema, bits, codeUnit), Tree.LeafCase('\uFFFF'))
    val complex = schema.scalar("Complex64", bits, Runtime.Complex::class.java)
    reject("ctor::Leaf.value") {
      Codecs.treeCodec(schema, bits, complex).encode(Tree.LeafCase(Runtime.Complex(0.1, 0.0)))
    }
    val double = schema.scalar("Float64", bits, Double::class.javaObjectType)
    val floatTree = Codecs.treeCodec(schema, bits, double)
    for (value in listOf(Double.NaN, -0.0, Double.POSITIVE_INFINITY)) {
      val encoded = floatTree.encode(Tree.LeafCase(value))
      val decoded = floatTree.decode(encoded) as Tree.LeafCase
      if (value.isNaN()) {
        check(decoded.value.isNaN())
        check(!schema.equal(floatTree.type(), encoded, encoded, bits))
      } else check(decoded.value.toRawBits() == value.toRawBits())
    }
    reject("invalid constructor arity") {
      tree.decode(Runtime.Value(LawSpecSchema.key(tree.type()), Runtime.Data("ctor::Leaf", emptyList())))
    }
    val empty = Codecs.emptyCodec(schema, bits, byte)
    check(runCatching {
      empty.decode(Runtime.Value(LawSpecSchema.key(empty.type()), Runtime.Data("fake", emptyList())))
    }.isFailure)
  }
  println("Kotlin typed codec round trips and contextual rejection passed")
}
