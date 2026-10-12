// User-owned LawSpec adapter.
package example

object Harness {
  // (example.harness::type::Order -> Int32)
  // Ten percent off orders of more than ten items.
  def discount(value0: lawspec.data.Order): scala.Int = if (value0.items > 10) value0.total / 10 else 0

  // (Int32 -> Int32)
  // To the nearest ten cents, halves down: known to break a law.
  def roundCents(value0: scala.Int): scala.Int = (value0 + 4) / 10 * 10

  // (Int32 -> Bool)
  def book(ledger: lawspec.abilities.example.Harness.Ledger, value0: scala.Int): scala.Boolean =
    ledger.accept(value0)

  /** The native handler of Ledger: accept. */
  class LedgerHandler extends lawspec.abilities.example.Harness.Ledger {
    override def accept(value0: scala.Int): scala.Boolean = value0 > 0
  }
}
