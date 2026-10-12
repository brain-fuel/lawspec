// User-owned LawSpec adapter: an account's handlers, run inside an actor.
package example

import lawspec.actors.AccountActor
import lawspec.actors.BankSupervisor
import lawspec.data.Account
import lawspec.data.Pair
import lawspec.runtime.LawSpecRuntime
import lawspec.runtime.LawSpecRuntime.Value

@groovy.transform.CompileStatic
final class Actors {
  static Account openAccount(Value value0) {
    return new Account(0L)
  }

  static Pair<Long, Account> deposit(Account value0, short value1) {
    long after = value0.balance() + value1
    return new Pair<>(after, new Account(after))
  }

  static Pair<Long, Account> withdrawAll(Account value0) {
    return new Pair<>(value0.balance(), new Account(0L))
  }

  static Pair<Long, Account> balance(Account value0) {
    return new Pair<>(value0.balance(), value0)
  }

  static Account close(Account value0) {
    return new Account(0L)
  }

  static long depositTwice(short value0) {
    var account = AccountActor.start()
    LawSpecRuntime.par(() -> account.deposit(value0), () -> account.deposit(value0))
    long total = account.balance()
    account.stop()
    return total
  }

  static Account reopen(Account value0) {
    return new Account(value0.balance())
  }

  static long survivesCrash(short value0) {
    var bank = BankSupervisor.start()
    bank.account.deposit(value0)
    bank.account.crash()
    long total = bank.account.balance()
    bank.stop()
    return total
  }
}
