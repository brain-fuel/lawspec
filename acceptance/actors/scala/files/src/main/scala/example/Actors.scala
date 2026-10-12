// User-owned LawSpec adapter: an account's handlers, run inside an actor.
package example

import lawspec.actors.{AccountActor, BankSupervisor}
import lawspec.data.{Account, Pair}
import lawspec.runtime.LawSpecRuntime

object Actors {
  // (Unit -> example.actors::type::Account)
  def openAccount(value0: scala.Unit): lawspec.data.Account = Account(0)

  // (example.actors::type::Account -> (UInt8 -> lawspec.collections::type::Pair (Int64)
  // (example.actors::type::Account)))
  def deposit(
    value0: lawspec.data.Account,
    value1: scala.Short,
  ): lawspec.data.Pair[scala.Long, lawspec.data.Account] = {
    val after = value0.balance + value1
    Pair(after, Account(after))
  }

  // (example.actors::type::Account -> lawspec.collections::type::Pair (Int64)
  // (example.actors::type::Account))
  def withdrawAll(
    value0: lawspec.data.Account,
  ): lawspec.data.Pair[scala.Long, lawspec.data.Account] = Pair(value0.balance, Account(0))

  // (example.actors::type::Account -> lawspec.collections::type::Pair (Int64)
  // (example.actors::type::Account))
  def balance(value0: lawspec.data.Account): lawspec.data.Pair[scala.Long, lawspec.data.Account] =
    Pair(value0.balance, value0)

  // (example.actors::type::Account -> example.actors::type::Account)
  def close(value0: lawspec.data.Account): lawspec.data.Account = Account(0)

  // (example.actors::type::Account -> example.actors::type::Account)
  def reopen(value0: lawspec.data.Account): lawspec.data.Account = Account(value0.balance)

  // (UInt8 -> Int64)
  def depositTwice(value0: scala.Short): scala.Long = {
    val account = AccountActor.start()
    LawSpecRuntime.par(() => { account.deposit(value0); () }, () => { account.deposit(value0); () })
    val total = account.balance()
    account.stop()
    total
  }

  // (UInt8 -> Int64)
  def survivesCrash(value0: scala.Short): scala.Long = {
    val bank = BankSupervisor.start()
    bank.account.deposit(value0)
    bank.account.crash()
    val total = bank.account.balance()
    bank.stop()
    total
  }
}
