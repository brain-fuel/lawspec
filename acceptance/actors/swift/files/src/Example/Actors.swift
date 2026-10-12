// User-owned LawSpec adapter: an account's handlers, run inside an actor.
// ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Actors {
    static func openAccount() -> Account { Account(balance: 0) }

    static func deposit(_ account: Account, _ amount: UInt8) -> Pair<Int64, Account> {
        let after = account.balance + Int64(amount)
        return Pair(first: after, second: Account(balance: after))
    }

    static func withdrawAll(_ account: Account) -> Pair<Int64, Account> {
        Pair(first: account.balance, second: Account(balance: 0))
    }

    static func balance(_ account: Account) -> Pair<Int64, Account> { Pair(first: account.balance, second: account) }

    static func close(_ account: Account) -> Account { Account(balance: 0) }

    static func reopen(_ account: Account) -> Account { Account(balance: account.balance) }

    /// This unit's account actor runs these functions.
    private static let handlers = LawSpec.Actors.AccountActorHandlers(
        openAccount: openAccount, deposit: deposit, withdrawAll: withdrawAll, balance: balance, close: close, reopen: reopen)

    static func depositTwice(_ amount: UInt8) -> Int64 {
        let account = try! LawSpec.Actors.AccountActor.start(handlers)
        let callers = DispatchGroup()
        for _ in 0..<2 {
            callers.enter()
            LawThread.start {
                try! account.deposit(amount)
                callers.leave()
            }
        }
        callers.wait()
        let total = try! account.balance()
        account.stop()
        return total
    }

    static func survivesCrash(_ amount: UInt8) -> Int64 {
        let bank = try! LawSpec.Actors.BankSupervisor.start(handlers)
        try! bank.account.deposit(amount)
        try! bank.account.crash()
        let total = try! bank.account.balance()
        bank.stop()
        return total
    }
}
