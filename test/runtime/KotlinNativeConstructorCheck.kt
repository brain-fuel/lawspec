import java.math.BigInteger
import lawspec.data.Bucket
import lawspec.data.Choice
import lawspec.data.Gap
import lawspec.data.Guarded
import lawspec.data.Identity
import lawspec.data.Machine
import lawspec.data.Positives
import lawspec.data.Raw
import lawspec.definitions.fixture.Fields
import lawspec.runtime.LawSpecDataCodecs
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecKotlin as Native
import lawspec.runtime.LawSpecKotlinCodecs
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecSchema.Named

private fun rejected(action: () -> Unit) {
    try {
        action()
    } catch (expected: IllegalArgumentException) {
        check(expected.message!!.contains("field refinement"))
        check(!expected.message!!.contains("division by zero"))
        return
    }
    error("invalid native constructor accepted")
}

fun main(args: Array<String>) {
    val bits = args[0].toInt()
    val symbols = mutableMapOf<String, Any>()
    val gap = Fields.inverseGap(symbols, Gap.GapCase(-128, 127))
    check(gap.n() == BigInteger.ONE && gap.d() == BigInteger.valueOf(255))
    rejected { Fields.inverseGap(symbols, Gap.GapCase(0, 0)) }
    rejected { Fields.inverseGap(symbols, Gap.GapCase(127, -128)) }
    Fields.echoBucket(symbols, Bucket.BucketCase(listOf(1)))
    rejected { Fields.echoBucket(symbols, Bucket.BucketCase(emptyList())) }
    Fields.echoPositives(symbols, Positives.PositivesCase(listOf(1)))
    rejected { Fields.echoPositives(symbols, Positives.PositivesCase(listOf(0))) }
    Fields.echoChoice(symbols, Choice.AcceptedCase(1))
    Fields.echoChoice(symbols, Choice.RejectedCase("no"))
    rejected { Fields.echoChoice(symbols, Choice.AcceptedCase(0)) }
    Fields.echoGuarded(symbols, Guarded.GuardedCase(2))
    rejected { Fields.echoGuarded(symbols, Guarded.GuardedCase(0)) }
    Fields.echoMachine(symbols, Machine.MachineCase(BigInteger.ONE))
    rejected { Fields.echoMachine(symbols, Machine.MachineCase(BigInteger.ZERO)) }
    if (bits == 64) {
        Fields.echoMachine(symbols, Machine.MachineCase(BigInteger.ONE.shiftLeft(40)))
    } else {
        try {
            Fields.echoMachine(symbols, Machine.MachineCase(BigInteger.ONE.shiftLeft(40)))
            error("unchecked machine range")
        } catch (expected: IllegalArgumentException) {
            check(expected.message!!.contains("IntSize"))
        }
    }
    val schema = LawSpecDataSchema.create()
    val token = Runtime.symbol("fixture", "same", symbols)
    val symbol = LawSpecKotlinCodecs.symbol(schema, bits).decode(token)
    val identity = Identity.IdentityCase(symbol)
    check((Fields.echoIdentity(symbols, identity) as Identity.IdentityCase).value == symbol)
    rejected { Fields.echoIdentity(mutableMapOf(), identity) }
    rejected { Fields.echoIdentity(symbols, Identity.IdentityCase(Native.Symbol("same"))) }
    Fields.echoIdentityBucket(symbols, Bucket.BucketCase(listOf(identity)))
    rejected { Fields.echoIdentityBucket(mutableMapOf(), Bucket.BucketCase(listOf(identity))) }
    val nested: Native.Optional<Native.Nullable<Identity>> =
        Native.Optional.Present(Native.Nullable.Present(identity))
    Fields.echoNested(symbols, nested)
    rejected { Fields.echoNested(mutableMapOf(), nested) }
    check(Fields.echoNested(symbols, Native.Optional.Undefined()) is Native.Optional.Undefined)
    val presentNull = Fields.echoNested(symbols, Native.Optional.Present(Native.Nullable.Null()))
    check(presentNull is Native.Optional.Present && presentNull.value is Native.Nullable.Null)
    val list = Fields.echoList(symbols, listOf(Runtime.Nothing(), Runtime.Just(identity)))
    check(list.size == 2)
    val codec = LawSpecDataCodecs.identityCodec(schema, bits, symbols)
    val logical = codec.encode(identity)
    check((codec.decode(logical) as Identity.IdentityCase).value == symbol)
    Fields.echoNullable(symbols, Native.Nullable.Null())
    Fields.echoNullable(symbols, Native.Nullable.Present(identity))
    rejected { Fields.echoNullable(mutableMapOf(), Native.Nullable.Present(identity)) }
    Fields.echoOptional(symbols, Native.Optional.Undefined())
    Fields.echoOptional(symbols, Native.Optional.Present(identity))
    rejected { Fields.echoOptional(mutableMapOf(), Native.Optional.Present(identity)) }
    check((Fields.echoRaw(symbols, Raw.RawCase('\ud800')) as Raw.RawCase).value == '\ud800')
    rejected { Fields.echoRaw(symbols, Raw.RawCase('a')) }
    val type = Named("List", Named("fixture.fields::type::Identity"))
    val empty = LawSpecKotlinCodecs.construct(schema, type, "List::Nil", emptyList(), bits, symbols)
    val cons = LawSpecKotlinCodecs.construct(
        schema, type, "List::Cons", listOf(logical, empty), bits, symbols,
    )
    check(LawSpecKotlinCodecs.match(schema, type, cons, bits, symbols) { tag, fields ->
        check(tag == "List::Cons")
        fields[0]
    } == logical)
    println("Kotlin native constructor contracts and contexts pass: $bits")
}
