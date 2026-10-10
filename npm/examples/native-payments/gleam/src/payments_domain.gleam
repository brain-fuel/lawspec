//// Application-owned payment types; no generated domain declarations.
import gleam/option.{type Option}
import lawspec/scalar
import lawspec/types

pub type CurrencyCode {
  Dollars
  Euros
  Pounds
}

// Field order deliberately differs from the specification and binding JSON.
pub type Price {
  Price(unit: CurrencyCode, major: types.Decimal)
}

pub type PaymentStatus {
  Settled(price: Price)
  Rejected(explanation: String)
}

pub fn apply_fee(price: Price) -> Price {
  Price(..price, major: scalar.decimal_add(price.major, scalar.decimal(2, -1)))
}

pub fn restore(payment: PaymentStatus) -> PaymentStatus {
  payment
}

pub fn store(payments: List(Option(PaymentStatus))) -> List(Option(PaymentStatus)) {
  payments
}
