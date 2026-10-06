package till

import lawspec.abilities.example.Till.Drawer

// Application code the till's bindings name: its own money type, a till
// that is the production handler, and payments that throw its own errors.
data class Cash(val cents: Long)

class CardDeclined : RuntimeException("declined")

class BadAmount(message: String) : RuntimeException(message)

class NativeTill {
    private var taken = 0L

    fun take(money: Cash): Cash {
        taken += money.cents
        return Cash(money.cents)
    }

    fun opening(): Cash = Cash(0)
}

// A bound adapter. It gets its drawer as the generated interface.
object Payments {
    fun pay(till: Drawer, cents: Long): Cash {
        if (cents < 0) throw BadAmount("negative")
        if (cents > 1000) throw CardDeclined()
        return Cash(till.take(lawspec.data.Money(cents)).cents)
    }
}
