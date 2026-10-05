// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, non_snake_case)]
use crate::lawspec_data::{Account, Pair};
use crate::lawspec_runtime as ls;

// An account's handlers, run inside an actor.
pub fn openAccount(value0: ()) -> Account {
    Account { balance: 0 }
}

pub fn deposit(value0: Account, value1: u8) -> Pair<i64, Account> {
    let after = value0.balance + i64::from(value1);
    Pair { first: after, second: Account { balance: after } }
}

pub fn withdrawAll(value0: Account) -> Pair<i64, Account> {
    Pair { first: value0.balance, second: Account { balance: 0 } }
}

pub fn balance(value0: Account) -> Pair<i64, Account> {
    Pair { first: value0.balance, second: value0 }
}

pub fn close(value0: Account) -> Account {
    Account { balance: 0 }
}

// Implementation code uses the generated typed actor: two callers deposit
// at once.
pub fn depositTwice(value0: u8) -> i64 {
    let account = crate::lawspec_actors::AccountActor::start();
    let callers: Vec<_> = (0..2)
        .map(|_| {
            let account = account.clone();
            std::thread::spawn(move || account.deposit(value0).unwrap())
        })
        .collect();
    for caller in callers {
        caller.join().unwrap();
    }
    let total = account.balance().unwrap();
    account.stop();
    total
}

// After a crash, the account reopens with the balance it had.
pub fn reopen(value0: Account) -> Account {
    Account { balance: value0.balance }
}

// The bank supervisor restarts a crashed account from its last balance.
pub fn survivesCrash(value0: u8) -> i64 {
    let bank = crate::lawspec_actors::BankSupervisor::start();
    bank.account.deposit(value0).unwrap();
    bank.account.crash().unwrap();
    let total = bank.account.balance().unwrap();
    bank.stop();
    total
}
