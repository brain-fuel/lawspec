// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
package example

object Abilities {
  // (Int32 -> Bool)
  def charge(
    gateway: lawspec.abilities.example.Abilities.Gateway,
    value0: scala.Int,
  ): scala.Boolean =
    gateway.authorize(value0) match {
      case lawspec.data.Payment.Approved(cents) => gateway.capture(cents).cents == value0
      case _ => false
    }

  /** The native handler of Gateway: authorize, capture, fee. */
  class GatewayHandler extends lawspec.abilities.example.Abilities.Gateway {
    override def authorize(
      value0: scala.Int,
    ): lawspec.data.Payment =
      if (value0 < 0) lawspec.data.Payment.Declined else lawspec.data.Payment.Approved(value0)
    override def capture(
      value0: scala.Int,
    ): lawspec.data.Receipt = lawspec.data.Receipt(value0)
    override def fee(): scala.Int = 25
  }
}
