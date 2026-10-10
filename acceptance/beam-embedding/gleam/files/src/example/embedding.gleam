// User-owned LawSpec adapter: an application that makes spec handlers itself.
import lawspec/abilities/example/embedding as abilities
import lawspec/data
import lawspec/effects

pub fn embed(n: Int) -> Int {
  effects.with_context(fn(context) {
    let tally = abilities.keeping(context)
    abilities.keeping_set_state(tally, 10)
    let assert Error(data.RefusalNegative) = abilities.tally_try_add(tally, -1)
    let assert Ok(_) = abilities.tally_try_add(tally, n)
    abilities.keeping_state(tally)
  })
}

pub fn share_book(n: Int) -> Int {
  effects.with_context(fn(context) {
    let #(ledger, balance) = abilities.book(context)
    abilities.ledger_record(ledger, n)
    abilities.balance_balance(balance)
  })
}

pub fn tally_handler() -> abilities.Tally {
  abilities.tally(fn(n) { n })
}

pub fn ledger_handler() -> abilities.Ledger {
  abilities.ledger(fn(_) { Nil })
}

pub fn balance_handler() -> abilities.Balance {
  abilities.balance(fn() { 0 })
}
