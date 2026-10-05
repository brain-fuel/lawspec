// User-owned LawSpec adapter: the native Gateway handler.
package example

object Failures {
    /** The native handler of Gateway: decide. */
    class GatewayHandler : lawspec.abilities.example.Failures.Gateway {
        override fun decide(value0: kotlin.Int): lawspec.data.Decision = when {
            value0 < 0 -> lawspec.data.Decision.Block
            value0 % 2 == 1 -> lawspec.data.Decision.Decline("an odd amount")
            else -> lawspec.data.Decision.Approve
        }
    }
}
