// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{PeekFlow, PopFlow, PushFlow, Stack};

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
