package domain

import groovy.transform.CompileStatic
import lawspec.runtime.LawSpecRuntime.Maybe

/**
 * Application types, independent of generated LawSpec domain declarations.
 * The records write out their constructors and accessors, which the Java
 * model reads through Groovy's joint-compilation stubs.
 */
@CompileStatic
final class PaymentsDomain {
  private PaymentsDomain() {}

  enum CurrencyCode { Dollars, Euros, Pounds }

  static record Price(BigDecimal major, CurrencyCode unit) {
    Price(BigDecimal major, CurrencyCode unit) {
      this.major = major
      this.unit = unit
    }

    BigDecimal major() { major }

    CurrencyCode unit() { unit }
  }

  static interface PaymentStatus {}

  static record Settled(Price price) implements PaymentStatus {
    Settled(Price price) { this.price = price }

    Price price() { price }
  }

  static record Rejected(String explanation) implements PaymentStatus {
    Rejected(String explanation) { this.explanation = explanation }

    String explanation() { explanation }
  }

  static Price apply_fee(Price price) {
    new Price(price.major() + new BigDecimal('0.2'), price.unit())
  }

  static PaymentStatus restore(PaymentStatus payment) { payment }

  static List<Maybe<PaymentStatus>> store(List<Maybe<PaymentStatus>> payments) { payments }
}
