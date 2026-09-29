package domain

import io.kotest.property.Arb
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import java.math.BigDecimal

object PaymentGenerators {
    fun prices(): Arb<PaymentsDomain.Price> = Arb.int(100..200).map { cents ->
        PaymentsDomain.Price(BigDecimal.valueOf(cents.toLong(), 2), PaymentsDomain.CurrencyCode.Euros)
    }
}
