// Scaffolded by LawSpec. User-owned; never overwritten.
// The portable generator under test.
use crate::lawspec_runtime as ls;

pub fn generated(value0: String, value1: u64, value2: i32, value3: i32) -> Vec<String> {
    ls::generated(&value0, value1, value2.into(), value3.into())
}

pub fn shrunk(value0: String, value1: u64, value2: i32) -> Vec<String> {
    ls::shrunk(&value0, value1, value2.into())
}
