// Scaffolded by LawSpec. User-owned; never overwritten.
// class is not a Rust keyword, so the adapter keeps its name.
use crate::lawspec_runtime as ls;

pub fn class(value0: ls::BigInt) -> ls::BigInt {
    value0.clone() + value0
}
