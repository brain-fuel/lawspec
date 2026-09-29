package domain;

import java.math.BigDecimal;
import java.math.BigInteger;
import org.jetbrains.jetCheck.Generator;

public final class PaymentGenerators {
  private PaymentGenerators() {}

  public static final ThreadLocal<Integer> byteSamples = ThreadLocal.withInitial(() -> 0);

  public static Generator<PaymentsDomain.Price> prices() {
    return Generator.integers(100, 200)
        .map(
            cents ->
                new PaymentsDomain.Price(
                    new BigDecimal(BigInteger.valueOf(cents), 2),
                    PaymentsDomain.CurrencyCode.Euros));
  }

  public static <T> Generator<Shapes.Wrapped<T>> boxes(Generator<T> child) {
    return child.map(Shapes.Wrapped::new);
  }

  public static Generator<Byte> bytes() {
    return Generator.integers(6, 20)
        .map(
            value -> {
              byteSamples.set(byteSamples.get() + 1);
              return value.byteValue();
            });
  }

  public static Generator<Shapes.Seal> seals() {
    throw new AssertionError("finite Seal must be enumerated without factory sampling");
  }
}
