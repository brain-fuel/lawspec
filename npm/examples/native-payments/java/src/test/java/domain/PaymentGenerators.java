package domain;

import java.math.BigDecimal;
import java.math.BigInteger;
import org.jetbrains.jetCheck.Generator;

public final class PaymentGenerators {
  private PaymentGenerators() {}

  public static Generator<PaymentsDomain.Price> prices() {
    return Generator.integers(100, 200)
        .map(cents -> new PaymentsDomain.Price(
            new BigDecimal(BigInteger.valueOf(cents), 2),
            PaymentsDomain.CurrencyCode.Euros));
  }
}
