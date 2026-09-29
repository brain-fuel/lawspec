package domain

import io.kotest.property.Arb
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import java.math.BigDecimal
import java.util.concurrent.atomic.AtomicInteger

object PaymentGenerators {
    val byteSamples = AtomicInteger()

    fun prices(): Arb<PaymentsDomain.Price> = Arb.int(100..200).map { cents ->
        PaymentsDomain.Price(BigDecimal.valueOf(cents.toLong(), 2), PaymentsDomain.CurrencyCode.Euros)
    }

    fun <T> boxes(child: Arb<T>): Arb<Shapes.Wrapped<T>> = child.map { Shapes.Wrapped(it) }

    fun bytes(): Arb<Byte> = Arb.int(6..20).map {
        byteSamples.incrementAndGet()
        it.toByte()
    }

    fun texts(): Arb<String> = Arb.constant("application text")

    fun seals(): Arb<Shapes.Seal> = error("finite Seal must not invoke its generator")
}
