package domain

import java.math.BigDecimal
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecKotlin
import lawspec.runtime.LawSpecKotlinCodecs
import lawspec.runtime.LawSpecNativeCodecs

// A valid application subtype that was deliberately not mapped to LawSpec.
class UnexpectedPayment : PaymentsDomain.PaymentStatus

fun main(args: Array<String>) {
    val bits = args.single().toInt()
    val schema = LawSpecDataSchema.create()
    val symbols = mutableMapOf<String, Any>()
    val money = LawSpecNativeCodecs.moneyCodec(schema, bits, symbols)
    val value = PaymentsDomain.Price(BigDecimal("0.100000000000000000000001"), PaymentsDomain.CurrencyCode.Euros)
    check(money.decode(money.encode(value)) == value)
    val payment = LawSpecNativeCodecs.paymentCodec(schema, bits, symbols)
    val invalid = runCatching { payment.encode(UnexpectedPayment()) }.exceptionOrNull()
    check(invalid is IllegalArgumentException && invalid.message.orEmpty().contains("invalid native data"))

    val raw = LawSpecNativeCodecs.boxCodec(schema, bits, LawSpecKotlinCodecs.codePointText(schema, bits), symbols)
    val points = intArrayOf(0, 0xd800, 0x10ffff)
    check(raw.decode(raw.encode(Shapes.Wrapped(points))).stored.contentEquals(points))
    val bytes = LawSpecNativeCodecs.boxCodec(schema, bits, schema.scalar("Bytes", bits, ByteArray::class.java), symbols)
    check(bytes.decode(bytes.encode(Shapes.Wrapped(byteArrayOf(0, -1, -128)))).stored.contentEquals(byteArrayOf(0, -1, -128)))
    val utf16 = LawSpecNativeCodecs.boxCodec(schema, bits, schema.scalar("Utf16Text", bits, String::class.java), symbols)
    val units = "\ud800\u0000\udfff"
    check(utf16.decode(utf16.encode(Shapes.Wrapped(units))).stored == units)

    val symbol = LawSpecKotlinCodecs.symbol(schema, bits)
    val boxedSymbol = LawSpecNativeCodecs.boxCodec(schema, bits, symbol, symbols)
    val identity = LawSpecKotlin.Symbol("same description")
    val restored = boxedSymbol.decode(boxedSymbol.encode(Shapes.Wrapped(identity))).stored
    check(restored == identity)
    val other = LawSpecKotlin.Symbol("same description")
    check(!schema.equal(
        boxedSymbol.type(),
        boxedSymbol.encode(Shapes.Wrapped(identity)),
        boxedSymbol.encode(Shapes.Wrapped(other)),
        bits,
        symbols,
    ))

    val integer = schema.scalar("Int8", bits, Byte::class.javaObjectType)
    val nullable = LawSpecKotlinCodecs.nullable(schema, bits, integer, symbols)
    val optional = LawSpecKotlinCodecs.optional(schema, bits, nullable, symbols)
    val box = LawSpecNativeCodecs.boxCodec(schema, bits, optional, symbols)
    val absent: LawSpecKotlin.Optional<LawSpecKotlin.Nullable<Byte>> = LawSpecKotlin.Optional.Undefined()
    val presentNull: LawSpecKotlin.Optional<LawSpecKotlin.Nullable<Byte>> = LawSpecKotlin.Optional.Present(LawSpecKotlin.Nullable.Null())
    val encodedAbsent = box.encode(Shapes.Wrapped(absent))
    val encodedNull = box.encode(Shapes.Wrapped(presentNull))
    check(!schema.equal(box.type(), encodedAbsent, encodedNull, bits, symbols))
    check(schema.equal(box.type(), box.encode(box.decode(encodedAbsent)), encodedAbsent, bits, symbols))
    check(schema.equal(box.type(), box.encode(box.decode(encodedNull)), encodedNull, bits, symbols))
    println("Kotlin native source codecs: exact values, raw data, symbols, absence, invalid variants; bits=$bits")
}
