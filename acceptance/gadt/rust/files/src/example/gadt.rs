// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{Expr, Pair, Shown};
use crate::lawspec_runtime as ls;

// Rust enums cannot refine their type arguments per variant, so the other
// variants are unreachable here rather than absent; LawSpec's codecs check
// that every value of Expr<BigInt> is a number case.
pub fn evalNumber(value0: Expr<ls::Integer>) -> ls::BigInt {
    match value0 {
        Expr::Number { value, .. } => value.0,
        Expr::Plus { value, .. } => evalNumber(*value.left) + evalNumber(*value.right),
        _ => unreachable!("not an Expr<BigInt>"),
    }
}

pub fn evalTruth(value0: Expr<bool>) -> bool {
    match value0 {
        Expr::Truth { value, .. } => value,
        Expr::Same { value, .. } => evalNumber(*value.left) == evalNumber(*value.right),
        Expr::Negate { value, .. } => !evalTruth(*value),
        _ => unreachable!("not an Expr<bool>"),
    }
}

// Both's halves have existential types, which a Rust enum cannot name: they
// arrive as checked values, decoded at the types this one implies.
pub fn evalPair(value0: Expr<Pair<ls::Integer, bool>>) -> Pair<ls::Integer, bool> {
    let Expr::Both { value, .. } = value0 else { unreachable!("not an Expr<Pair>") };
    let payload: crate::lawspec_data::BothDetails<ls::Integer, bool> =
        ls::FromValue::from_value(value).expect("a paired expression");
    let first = payload.first;
    let second = payload.second;
    Pair { first: evalNumber(*first).into(), second: evalTruth(*second) }
}

pub fn fold(value0: Expr<ls::Integer>) -> Expr<ls::Integer> {
    Expr::Number { value: evalNumber(value0).into(), _lawspec_marker: std::marker::PhantomData }
}

pub fn describe(value0: Shown) -> String {
    value0.witness
}
