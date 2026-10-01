// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{Grid, Halves, Pairs, Perfect, Rest, Row};
use crate::lawspec_runtime as ls;

fn length(row: &Row) -> i64 {
    match row {
        Row::End => 0,
        Row::Cell { tail, .. } => 1 + length(tail),
    }
}

pub fn mirror(value0: Perfect) -> Perfect {
    match value0 {
        Perfect::Node { left, right } => Perfect::Node { left: Box::new(mirror(*right)), right: Box::new(mirror(*left)) },
        leaf => leaf,
    }
}

pub fn area(value0: Grid) -> ls::BigInt {
    ls::BigInt::from(length(&value0.rows) * length(&value0.columns))
}

pub fn duplicate(value0: Row) -> Halves {
    Halves { front: value0.clone(), back: value0 }
}

pub fn countPairs(value0: Row) -> Pairs {
    Pairs { items: value0 }
}

pub fn dropFirst(value0: Row) -> Rest {
    Rest { items: value0 }
}
