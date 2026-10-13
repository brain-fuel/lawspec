package domain

import groovy.transform.CompileStatic
import org.jetbrains.jetCheck.Generator

@CompileStatic
final class PaymentGenerators {
  private PaymentGenerators() {}

  static Generator<PaymentsDomain.Price> prices() {
    Generator.integers(100, 200).map { Integer cents ->
      new PaymentsDomain.Price(new BigDecimal(BigInteger.valueOf(cents), 2), PaymentsDomain.CurrencyCode.Euros)
    }
  }
}
