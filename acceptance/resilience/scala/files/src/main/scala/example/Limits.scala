// User-owned LawSpec adapter.
package example

import scala.concurrent.{ExecutionContext, Future, blocking}

object Limits {
  private given ExecutionContext = ExecutionContext.global

  def admitTicket(value0: lawspec.data.Ticket): Either[String, lawspec.data.Ticket] = Right(value0)

  def reserveSeat(value0: lawspec.data.Ticket): Either[String, lawspec.data.Ticket] = Right(value0)

  def chargeCard(value0: lawspec.data.Ticket): Either[String, lawspec.data.Ticket] =
    if (value0.number < 0) Left("declined") else Right(value0)

  def releaseSeat(value0: lawspec.data.Ticket): Boolean = true

  private val quotes = java.util.concurrent.atomic.AtomicLong()

  def resetQuotes(): Unit = quotes.set(0)

  // Ticket -2's first quote (and every other one after) stalls.
  def hedgeQuote(value0: lawspec.data.Ticket): Future[Either[String, lawspec.data.Ticket]] = {
    val stalls = value0.number == -2L && quotes.incrementAndGet() % 2 == 1L
    Future {
      if (stalls) blocking(Thread.sleep(600))
      Right(value0)
    }
  }

  // Ticket -1's quote takes 600ms.
  def fetchQuote(value0: lawspec.data.Ticket): Future[Either[String, lawspec.data.Ticket]] =
    Future {
      if (value0.number == -1L) blocking(Thread.sleep(600))
      Right(value0)
    }
}
