// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{Expr, Pair, Shown};
use crate::lawspec_runtime as ls;

// Rust enums cannot refine their type arguments per variant, so the other
// variants are unreachable here rather than absent; LawSpec's codecs check
// that every value of Expr<BigInt> is a number case.
pub fn evalNumber(value0: Expr<ls::BigInt>) -> ls::BigInt {
    match value0 {
        Expr::Number { value, .. } => value,
        Expr::Plus { left, right, .. } => evalNumber(*left) + evalNumber(*right),
        _ => unreachable!("not an Expr<BigInt>"),
    }
}

pub fn evalTruth(value0: Expr<bool>) -> bool {
    match value0 {
        Expr::Truth { value, .. } => value,
        Expr::Same { left, right, .. } => evalNumber(*left) == evalNumber(*right),
        Expr::Negate { operand, .. } => !evalTruth(*operand),
        _ => unreachable!("not an Expr<bool>"),
    }
}

// Both's halves have existential types, which a Rust enum cannot name: they
// arrive as checked values, decoded at the types this one implies.
pub fn evalPair(value0: Expr<Pair<ls::BigInt, bool>>) -> Pair<ls::BigInt, bool> {
    let Expr::Both { first, second, .. } = value0 else { unreachable!("not an Expr<Pair>") };
    let first: Expr<ls::BigInt> = ls::FromValue::from_value(first).expect("a number expression");
    let second: Expr<bool> = ls::FromValue::from_value(second).expect("a Boolean expression");
    Pair { first: evalNumber(first), second: evalTruth(second) }
}

pub fn fold(value0: Expr<ls::BigInt>) -> Expr<ls::BigInt> {
    Expr::Number { value: evalNumber(value0), _lawspec_marker: std::marker::PhantomData }
}

pub fn describe(value0: Shown) -> String {
    value0.witness
}
