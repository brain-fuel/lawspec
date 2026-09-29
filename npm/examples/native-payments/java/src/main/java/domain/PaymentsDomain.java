package domain;

import java.math.BigDecimal;
import java.util.List;
import lawspec.runtime.LawSpecRuntime.Maybe;

/** Application types, independent of generated LawSpec domain declarations. */
public final class PaymentsDomain {
  private PaymentsDomain() {}

  public enum CurrencyCode { Dollars, Euros, Pounds }

  public record Price(BigDecimal major, CurrencyCode unit) {}

  public sealed interface PaymentStatus permits Settled, Rejected {}

  public record Settled(Price price) implements PaymentStatus {}

  public record Rejected(String explanation) implements PaymentStatus {}

  public static Price apply_fee(Price price) {
    return new Price(price.major().add(new BigDecimal("0.2")), price.unit());
  }

  public static PaymentStatus restore(PaymentStatus payment) {
    return payment;
  }

  public static List<Maybe<PaymentStatus>> store(List<Maybe<PaymentStatus>> payments) {
    return payments;
  }
}
