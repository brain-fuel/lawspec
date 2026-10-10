// ref:REQ-harness-units ref:DEC-tests-cite-requirements
import lawspec/abilities/example/harness as ledger
import lawspec/data
pub fn discount(order: data.Order) -> Int {
  let data.Order(items, total) = order
  case items > 10 { True -> total / 10 False -> 0 }
}
pub fn round_cents(cents: Int) -> Int { { cents + 4 } / 10 * 10 }
pub fn book(handler: ledger.Ledger, cents: Int) -> Bool { ledger.ledger_accept(handler, cents) }
pub fn ledger_handler() -> ledger.Ledger { ledger.ledger(fn(cents) { cents > 0 }) }
