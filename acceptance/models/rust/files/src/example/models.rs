// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{Counter, PeekFlow, PopFlow, PushFlow, Stack};
use std::collections::HashMap;
use std::sync::Mutex;

static COUNTERS: Mutex<(i32, Option<HashMap<i32, i64>>)> = Mutex::new((0, None));

pub fn empty(value0: ()) -> Stack {
    Stack::Empty
}

pub fn push(value0: i8, value1: Stack) -> PushFlow {
    PushFlow { state: Stack::Push { top: value0, rest: Box::new(value1) } }
}

// The flow signature guarantees a nonempty stack.
pub fn pop(value0: Stack) -> PopFlow {
    match value0 {
        Stack::Push { top, rest } => PopFlow { result: top, state: *rest },
        Stack::Empty => unreachable!("pop needs a nonempty stack"),
    }
}

pub fn peek(value0: Stack) -> PeekFlow {
    match &value0 {
        Stack::Push { top, .. } => PeekFlow { result: *top, state: value0.clone() },
        Stack::Empty => unreachable!("peek needs a nonempty stack"),
    }
}

// Changes a counter atomically, under one lock.
fn change(id: i32, by: i64) -> i64 {
    let mut guard = COUNTERS.lock().unwrap();
    let counts = guard.1.get_or_insert_with(HashMap::new);
    let count = counts.entry(id).or_insert(0);
    *count += by;
    *count
}

pub fn newCounter(value0: ()) -> Counter {
    let mut guard = COUNTERS.lock().unwrap();
    guard.0 += 1;
    let id = guard.0;
    guard.1.get_or_insert_with(HashMap::new).insert(id, 0);
    Counter { id }
}

pub fn increment(value0: Counter) -> i64 {
    change(value0.id, 1)
}

pub fn decrement(value0: Counter) -> i64 {
    change(value0.id, -1)
}

pub fn read(value0: Counter) -> i64 {
    change(value0.id, 0)
}
