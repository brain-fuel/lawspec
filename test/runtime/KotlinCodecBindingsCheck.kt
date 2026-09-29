import domain.CodecDomain
import lawspec.runtime.LawSpecDataSchema
import lawspec.runtime.LawSpecNativeCodecs

fun main(args: Array<String>) {
    val bits = args[0].toInt()
    val schema = LawSpecDataSchema.create()
    val symbols = mutableMapOf<String, Any>()
    val child = LawSpecNativeCodecs.parcelCodec(
        schema, bits, schema.scalar("Int8", bits, Byte::class.javaObjectType), symbols)
    val nested = LawSpecNativeCodecs.parcelCodec(schema, bits, child, symbols)
    val value = CodecDomain.Parcel(CodecDomain.Parcel(127.toByte()))
    check(nested.decode(nested.encode(value)).unpack().unpack() == 127.toByte())
    println("Source-only Kotlin nested codec conversion passes")
}
