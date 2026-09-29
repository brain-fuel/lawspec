// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{Tree, Vec};
use crate::lawspec_runtime as ls;

pub fn replicate(value0: ls::BigInt, value1: i8) -> Vec<i8> {
    let mut result = Vec::VNil;
    let mut count = value0;
    while count > ls::BigInt::from(0) {
        result = Vec::VCons { head: value1, tail: Box::new(result) };
        count -= 1;
    }
    result
}

pub fn append(value0: Vec<i8>, value1: Vec<i8>) -> Vec<i8> {
    match value0 {
        Vec::VNil => value1,
        Vec::VCons { head, tail } => Vec::VCons { head, tail: Box::new(append(*tail, value1)) },
    }
}

pub fn zip(value0: Vec<i8>, value1: Vec<bool>) -> Vec<bool> {
    match (value0, value1) {
        (Vec::VCons { tail: a, .. }, Vec::VCons { head, tail: b }) => Vec::VCons { head, tail: Box::new(zip(*a, *b)) },
        _ => Vec::VNil,
    }
}

pub fn flatten(value0: Tree<i8>) -> Vec<i8> {
    match value0 {
        Tree::Tip => Vec::VNil,
        Tree::Bin { left, value, right } => {
            let right = Vec::VCons { head: value, tail: Box::new(flatten(*right)) };
            append(flatten(*left), right)
        }
    }
}
