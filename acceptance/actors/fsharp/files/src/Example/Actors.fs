// User-owned LawSpec adapter: an account's handlers, run inside an actor.
module Example.Actors

open System.Threading.Tasks
open LawSpec.Data
open LawSpec.Actors

let openAccount () : Account = { Balance = 0L }

let deposit (account: Account) (amount: byte) : Pair<int64, Account> =
    let after = account.Balance + int64 amount
    { First = after; Second = { Balance = after } }

let withdrawAll (account: Account) : Pair<int64, Account> =
    { First = account.Balance; Second = { Balance = 0L } }

let balance (account: Account) : Pair<int64, Account> = { First = account.Balance; Second = account }

let close (_: Account) : Account = { Balance = 0L }

let reopen (account: Account) : Account = { Balance = account.Balance }

/// This unit's account actor runs these functions.
let private handlers: AccountActorHandlers =
    { OpenAccount = openAccount
      Deposit = deposit
      WithdrawAll = withdrawAll
      Balance = balance
      Close = close
      Reopen = reopen }

let depositTwice (amount: byte) : int64 =
    let account = AccountActor.Start handlers
    Task.WaitAll(Task.Run(fun () -> account.Deposit amount |> ignore), Task.Run(fun () -> account.Deposit amount |> ignore))
    let total = account.Balance()
    account.Stop()
    total

let survivesCrash (amount: byte) : int64 =
    let bank = BankSupervisor.Start handlers
    bank.Account.Deposit amount |> ignore
    bank.Account.Crash()
    let total = bank.Account.Balance()
    bank.Stop()
    total
