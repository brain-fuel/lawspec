package domain

import lawspec.testing.Arb

object PaymentGenerators {
  def prices(): Arb[PaymentsDomain.Price] = Arb.int(100 to 200).map(cents =>
    PaymentsDomain.Price(BigDecimal(BigInt(cents), 2), PaymentsDomain.CurrencyCode.Euros))
}
