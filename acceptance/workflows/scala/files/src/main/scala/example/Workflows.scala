// User-owned LawSpec adapter.
package example

import lawspec.data.Account
import lawspec.data.Order
import lawspec.data.Signup
import lawspec.data.SignupError
import scala.concurrent.{ExecutionContext, Future, blocking}

object Workflows {
  private given ExecutionContext = ExecutionContext.global

  def audit(value0: Account): Boolean = true

  def waitlist(value0: SignupError): Either[SignupError, Account] = {
    if (value0 == SignupError.Unavailable) return Right(Account("waitlist", 18, 0))
    Left(value0)
  }

  def checkName(value0: Signup): Either[SignupError, Signup] = {
    if (value0.name.isEmpty) return Left(SignupError.MissingName)
    Right(value0)
  }

  def checkAge(value0: Signup): Either[String, Signup] = {
    if (value0.age < 18) return Left("too young")
    Right(value0)
  }

  def openAccount(value0: Signup): Either[SignupError, Account] = {
    if (value0.name == "taken") return Left(SignupError.Unavailable)
    Right(Account(value0.name, value0.age, 1))
  }

  // Each check records when it fails, so approvalErrors can tell completion
  // order from declaration order.
  val finished: java.util.List[String] = java.util.Collections.synchronizedList(java.util.ArrayList[String]())

  private def check(value0: Order, milliseconds: Long, problem: String): Future[Either[String, Order]] =
    Future {
      if (value0.number == -1L) blocking(Thread.sleep(milliseconds))
      if (value0.number >= 0) Right(value0)
      else {
        finished.add(problem)
        Left(problem)
      }
    }

  // Order -1's stock check takes 400ms; a negative order has no stock.
  def checkStock(value0: Order): Future[Either[String, Order]] = check(value0, 400, "no stock")

  // Order -1's credit check takes 250ms; a negative order has no credit.
  def checkCredit(value0: Order): Future[Either[String, Order]] = check(value0, 250, "no credit")
}
