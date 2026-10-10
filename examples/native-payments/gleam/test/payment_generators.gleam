import lawspec/scalar
import payments_domain
import qcheck

// qcheck.map preserves the integer generator's native shrink tree.
pub fn prices() -> qcheck.Generator(payments_domain.Price) {
  qcheck.map(qcheck.bounded_int(100, 200), fn(cents) {
    payments_domain.Price(
      unit: payments_domain.Euros,
      major: scalar.decimal(cents, -2),
    )
  })
}
