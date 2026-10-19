// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{PeekFlow, PopFlow, PushFlow, Stack};

pub fn push(value0: i8, value1: Stack) -> PushFlow {
    PushFlow { state: Stack::Push { value: Box::new(crate::lawspec_data::Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be { top: value0, rest: Box::new(value1) }) } }
}

// The flow signature guarantees a nonempty stack.
pub fn pop(value0: Stack) -> PopFlow {
    match value0 {
        Stack::Push { value } => PopFlow { result: value.top, state: *value.rest },
        Stack::Empty => unreachable!("pop needs a nonempty stack"),
    }
}

pub fn peek(value0: Stack) -> PeekFlow {
    match &value0 {
        Stack::Push { value } => PeekFlow { result: value.top, state: value0.clone() },
        Stack::Empty => unreachable!("peek needs a nonempty stack"),
    }
}
