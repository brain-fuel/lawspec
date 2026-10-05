// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
package example

import lawspec.runtime.LawSpecRuntime

object Abilities {
    // (Int32 -> Bool)
    fun charge(
        gateway: lawspec.abilities.example.Abilities.Gateway,
        value0: kotlin.Int,
    ): kotlin.Boolean {
        val payment = gateway.authorize(value0)
        return if (payment is lawspec.data.Payment.Approved) gateway.capture(payment.cents).cents == value0 else false
    }

    /** The native handler of Gateway: authorize, capture, fee. */
    class GatewayHandler : lawspec.abilities.example.Abilities.Gateway {
        override fun authorize(value0: kotlin.Int): lawspec.data.Payment =
            if (value0 < 0) lawspec.data.Payment.Declined else lawspec.data.Payment.Approved(value0)
        override fun capture(value0: kotlin.Int): lawspec.data.Receipt = lawspec.data.Receipt(value0)
        override fun fee(): kotlin.Int = 25
    }
}
