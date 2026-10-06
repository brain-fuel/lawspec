// User-owned LawSpec adapters for the tables example.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Int32 -> (Int32 -> Int32))
pub fn shippingCost(value0: i32, value1: i32) -> i32 {
    value0 * value1 + 5 * value0
}

// LawSpec: (Int32 -> Text)
pub fn label(value0: i32) -> String {
    format!("parcel {value0}")
}
