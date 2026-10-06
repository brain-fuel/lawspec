// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through LawSpecRuntime.Fail.
package example

import lawspec.runtime.LawSpecRuntime

object Shop {
    // (Int32 -> Int32)
    fun refund(
        gateway: lawspec.abilities.example.Abilities.Gateway,
        value0: kotlin.Int,
    ): kotlin.Int {
        if (value0 > 100000) throw LawSpecRuntime.Fail(lawspec.data.PaymentError.TooLarge)
        return gateway.capture(value0).cents
    }

    /** The native handler of Journal: note. */
    class JournalHandler : lawspec.abilities.example.Shop.Journal {
        private val lines = mutableListOf<String>()
        override fun note(value0: kotlin.String) {
            lines.add(value0)
        }
    }

    /** The native handler of Store Int32: load, save. */
    class StoreInt32Handler : lawspec.abilities.example.Shop.StoreInt32 {
        private var value = 0
        override fun load(): kotlin.Int = value
        override fun save(value0: kotlin.Int) {
            value = value0
        }
    }

    /** The native handler of Store Text: load, save. */
    class StoreTextHandler : lawspec.abilities.example.Shop.StoreText {
        private var value = ""
        override fun load(): kotlin.String = value
        override fun save(value0: kotlin.String) {
            value = value0
        }
    }

    /** The native handler of Meter: reading. */
    class MeterHandler : lawspec.abilities.example.Shop.Meter {
        override fun reading(): kotlin.Int = 3
    }
}
