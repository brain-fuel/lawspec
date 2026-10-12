package domain

// Application-owned types; no generated LawSpec domain declarations.
object PaymentsDomain {
  enum CurrencyCode {
    case Dollars, Euros, Pounds
  }

  final case class Price(major: BigDecimal, unit: CurrencyCode)

  sealed trait PaymentStatus
  final case class Settled(price: Price) extends PaymentStatus
  final case class Rejected(explanation: String) extends PaymentStatus

  def apply_fee(price: Price): Price = Price(price.major + BigDecimal("0.2"), price.unit)
  def restore(payment: PaymentStatus): PaymentStatus = payment
  def store(payments: List[Option[PaymentStatus]]): List[Option[PaymentStatus]] = payments
}
