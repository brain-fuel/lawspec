// User-owned LawSpec adapter: an account's handlers, run inside an actor.
package example

import lawspec.actors.AccountActor
import lawspec.actors.BankSupervisor
import lawspec.data.Account
import lawspec.data.Pair
import lawspec.runtime.LawSpecRuntime

object Actors {
    fun openAccount(value0: Unit): Account = Account(0)

    fun deposit(value0: Account, value1: Short): Pair<Long, Account> {
        val after = value0.balance + value1
        return Pair(after, Account(after))
    }

    fun withdrawAll(value0: Account): Pair<Long, Account> = Pair(value0.balance, Account(0))

    fun balance(value0: Account): Pair<Long, Account> = Pair(value0.balance, value0)

    fun close(value0: Account): Account = Account(0)

    fun depositTwice(value0: Short): Long {
        val account = AccountActor.start()
        LawSpecRuntime.par({ account.deposit(value0) }, { account.deposit(value0) })
        val total = account.balance()
        account.stop()
        return total
    }

    fun reopen(value0: Account): Account = Account(value0.balance)

    fun survivesCrash(value0: Short): Long {
        val bank = BankSupervisor.start()
        bank.account.deposit(value0)
        bank.account.crash()
        val total = bank.account.balance()
        bank.stop()
        return total
    }
}
