// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (example.harness::type::Order -> Int32)
pub fn discount(value0: crate::lawspec_data::Order) -> i32 {
    // Ten percent off orders of more than ten items.
    if value0.items > 10 { value0.total / 10 } else { 0 }
}

// LawSpec: (Int32 -> Int32)
pub fn roundCents(value0: i32) -> i32 {
    // To the nearest ten cents, halves down: known to break a law.
    (value0 + 4) / 10 * 10
}

// LawSpec: (Int32 -> Bool)
pub fn book(ledger: &dyn crate::lawspec_abilities::example_harness::Ledger, value0: i32) -> bool {
    ledger.accept(value0)
}

/// The native handler of Ledger: accept.
#[derive(Default)]
pub struct LedgerHandler;

impl crate::lawspec_abilities::example_harness::Ledger for LedgerHandler {
    fn accept(&self, value0: i32) -> bool {
        value0 > 0
    }
}
