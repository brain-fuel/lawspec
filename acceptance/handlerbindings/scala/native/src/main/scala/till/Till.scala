package till

import lawspec.abilities.example.Till.Drawer

// Application code the till's bindings name: its own money type, a till
// that is the production handler, and payments that throw its own errors.
final case class Cash(cents: Long)

class CardDeclined extends RuntimeException("declined")

class BadAmount(message: String) extends RuntimeException(message)

class NativeTill {
  private var taken = 0L

  def take(money: Cash): Cash = {
    taken += money.cents
    Cash(money.cents)
  }

  def opening(): Cash = Cash(0)
}

// A bound adapter. It gets its drawer as the generated trait.
object Payments {
  def pay(till: Drawer, cents: Long): Cash = {
    if (cents < 0) throw BadAmount("negative")
    if (cents > 1000) throw CardDeclined()
    Cash(till.take(lawspec.data.Money(cents)).cents)
  }
}
