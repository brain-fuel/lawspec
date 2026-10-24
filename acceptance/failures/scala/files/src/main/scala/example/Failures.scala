// User-owned LawSpec adapter: the native Gateway handler.
package example

import lawspec.data.{Decision, PaymentError}
import scala.concurrent.Future

object Failures {
  // Native adapters that fail: they give a Left with a PaymentError, which a
  // law expects with `fails with`.
  // (Int32 -> Int32)
  def refund(
      value0: scala.Int
  ): scala.util.Either[lawspec.data.PaymentError, scala.Int] =
    if (value0 > 5000) Left(PaymentError.TooLarge(5000))
    else Right(value0)

  // (Int32 -> Int32)
  def settle(
      value0: scala.Int
  ): scala.concurrent.Future[
    scala.util.Either[lawspec.data.PaymentError, scala.Int]
  ] =
    Future.successful {
      if (value0 < 0) Left(PaymentError.Blocked)
      else if (value0 == 0)
        Left(
          PaymentError.Declined(
            lawspec.data.DeclinedDetails("there is nothing to settle")
          )
        )
      else Right(value0)
    }

  /** The native handler of Gateway: decide. */
  class GatewayHandler extends lawspec.abilities.example.Failures.Gateway {
    override def decide(
        value0: scala.Int
    ): lawspec.data.Decision =
      if (value0 < 0) Decision.Block
      else if (value0 % 2 == 1) Decision.Decline("an odd amount")
      else Decision.Approve
  }
}
