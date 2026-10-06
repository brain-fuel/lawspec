// User-owned LawSpec adapter: the native Gateway handler.
package example

object Failures {
    // Native adapters that fail: they throw the runtime's Fail with a
    // PaymentError, which a law expects with `fails with`.
    fun refund(value0: kotlin.Int): kotlin.Int {
        if (value0 > 5000) throw lawspec.runtime.LawSpecRuntime.Fail(lawspec.data.PaymentError.TooLarge(5000))
        return value0
    }

    suspend fun settle(value0: kotlin.Int): kotlin.Int {
        kotlinx.coroutines.yield()
        if (value0 < 0) throw lawspec.runtime.LawSpecRuntime.Fail(lawspec.data.PaymentError.Blocked)
        if (value0 == 0) throw lawspec.runtime.LawSpecRuntime.Fail(lawspec.data.PaymentError.Declined("there is nothing to settle"))
        return value0
    }

    /** The native handler of Gateway: decide. */
    class GatewayHandler : lawspec.abilities.example.Failures.Gateway {
        override fun decide(value0: kotlin.Int): lawspec.data.Decision = when {
            value0 < 0 -> lawspec.data.Decision.Block
            value0 % 2 == 1 -> lawspec.data.Decision.Decline("an odd amount")
            else -> lawspec.data.Decision.Approve
        }
    }
}
