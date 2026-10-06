// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object Harness {
    // (example.harness::type::Order -> Int32)
    // Ten percent off orders of more than ten items.
    fun discount(value0: lawspec.data.Order): kotlin.Int = if (value0.items > 10) value0.total / 10 else 0

    // (Int32 -> Int32)
    // To the nearest ten cents, halves down: known to break a law.
    fun roundCents(value0: kotlin.Int): kotlin.Int = (value0 + 4) / 10 * 10

    // (Int32 -> Bool)
    fun book(ledger: lawspec.abilities.example.Harness.Ledger, value0: kotlin.Int): kotlin.Boolean =
        ledger.accept(value0)

    /** The native handler of Ledger: accept. */
    class LedgerHandler : lawspec.abilities.example.Harness.Ledger {
        override fun accept(value0: kotlin.Int): kotlin.Boolean = value0 > 0
    }
}
