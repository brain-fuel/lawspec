package domain

import java.math.BigDecimal
import lawspec.runtime.LawSpecRuntime.Maybe

// Application-owned types; no generated LawSpec domain declarations.
object PaymentsDomain {
    enum class CurrencyCode { Dollars, Euros, Pounds }
    data class Price(val major: BigDecimal, val unit: CurrencyCode)
    sealed interface PaymentStatus
    data class Settled(val price: Price) : PaymentStatus
    data class Rejected(val explanation: String) : PaymentStatus

    fun apply_fee(price: Price) = Price(price.major + BigDecimal("0.2"), price.unit)
    fun restore(payment: PaymentStatus) = payment
    fun store(payments: List<Maybe<PaymentStatus>>) = payments
}
