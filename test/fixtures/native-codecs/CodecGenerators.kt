package domain

import io.kotest.property.Arb
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map

object CodecGenerators {
    fun <T> parcels(child: Arb<T>): Arb<CodecDomain.Parcel<T>> = child.map { CodecDomain.Parcel(it) }
    fun bytes(): Arb<Byte> = Arb.int(1..100).map { it.toByte() }
    fun positives(): Arb<CodecDomain.Positive> = Arb.int(1..100).map { CodecDomain.Positive(it.toByte()) }
}
