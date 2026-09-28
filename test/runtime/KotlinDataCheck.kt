import java.math.BigInteger
import lawspec.data.*
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecKotlin as Native
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecSchema

fun main() {
  checkCodecs()
  checkStrategies()
  val shadow = lawspec.data.String.StringCase("native text")
  check(shadow.value.length == 11)
  val parameter: T0<Boolean> = T0.ParamCase(true)
  check((parameter as T0.ParamCase).value)
  val sameName: FooCase = FooCase.FooCase()
  check(sameName is FooCase.FooCase)
  val leaf: Tree<Byte> = Tree.LeafCase(127)
  val branch: Tree<Byte> = Tree.BranchCase(listOf(leaf, Tree.BranchCase(emptyList())))
  check((branch as Tree.BranchCase).children.size == 2)
  check((branch.children[0] as Tree.LeafCase).value == 127.toByte())
  val maximum = BigInteger("18446744073709551615")
  val pair: Pair<Boolean> = Pair.PairCase(true, maximum)
  check((pair as Pair.PairCase).first && pair.second == maximum)
  val phantom: Phantom<(Int) -> Int> = Phantom.TagCase()
  check(phantom is Phantom.TagCase)
  val mutual: LeftSide = LeftSide.AcrossCase(RightSide.BackCase(Runtime.Nothing()))
  check((mutual as LeftSide.AcrossCase).value is RightSide.BackCase)
  val states = listOf<Native.Nullable<Native.Optional<Byte>>>(
    Native.Nullable.Null(),
    Native.Nullable.Present(Native.Optional.Undefined()),
    Native.Nullable.Present(Native.Optional.Present(1)),
  )
  check(states.distinct().size == 3)
  val presence: Presence = Presence.StatesCase(states[1], Unit, Native.Null, Native.Undefined)
  check((presence as Presence.StatesCase).value is Native.Nullable.Present)
  val token = Runtime.SymbolValue("same description")
  val first = Native.Symbol(token)
  val alias = Native.Symbol(token)
  val second = Native.Symbol("same description")
  check(first == alias && first.hashCode() == alias.hashCode())
  check(first != second)
  val raw = Raw.RawCase(
    "\uD83D\uDE00", intArrayOf(0xD800), "\uD800", byteArrayOf(0, -1), first,
    Runtime.Ratio(BigInteger.ONE, BigInteger.TWO), Runtime.Complex(1.0, -0.0),
  )
  check(raw.text.codePointCount(0, raw.text.length) == 1)
  check(raw.points[0] == 0xD800 && raw.units[0].code == 0xD800)
  check(raw.bytes[1].toUByte().toInt() == 255)
  for (bits in listOf(32, 64)) {
    val schema = LawSpecDataSchema.create()
    val tree = LawSpecSchema.Named("Tree", LawSpecSchema.Named("Int8"))
    val value = schema.construct(tree, "ctor::Leaf", listOf(Runtime.integer("Int8", "127")), bits)
    check(schema.equal(tree, value, value, bits))
    val invalid = Runtime.Value("Tree Int8", Runtime.Data("ctor::Leaf", listOf(Runtime.integer("Int8", "128"))))
    check(runCatching { schema.validate(tree, invalid, bits) }.isFailure)
  }
  println("Kotlin native declarations, presence, identity, and schemas passed")
}
