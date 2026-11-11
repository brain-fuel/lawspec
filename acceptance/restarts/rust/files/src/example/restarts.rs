// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, non_snake_case)]
use crate::lawspec_data::{Pair, Tab};

// A tab's handlers, run inside an actor.
pub fn openTab(value0: ()) -> Tab {
    Tab { total: 0 }
}

pub fn add(value0: Tab, value1: u8) -> Pair<i64, Tab> {
    let after = value0.total + i64::from(value1);
    Pair {
        first: after,
        second: Tab { total: after },
    }
}

pub fn total(value0: Tab) -> Pair<i64, Tab> {
    Pair {
        first: value0.total,
        second: value0,
    }
}

// The bar supervisor restarts a crashed tab with the total it had.
pub fn keepsTotal(value0: u8) -> i64 {
    let bar = crate::lawspec_actors::BarSupervisor::start();
    bar.tab.add(value0).unwrap();
    bar.tab.crash().unwrap();
    let total = bar.tab.total().unwrap();
    bar.stop();
    total
}
