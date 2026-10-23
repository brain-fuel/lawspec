// User-owned LawSpec adapter.
use crate::lawspec_data::{Tree, Vec};
use crate::lawspec_data::VConsDetails as VectorCell;
use crate::lawspec_data::BinDetails as BinaryNode;
use crate::lawspec_runtime as ls;

fn nil<T>() -> Vec<T> {
    Vec::VNil { _lawspec_marker: std::marker::PhantomData }
}

fn prepend<T>(head: T, tail: Vec<T>) -> Vec<T> {
    Vec::VCons { value: Box::new(VectorCell { head, tail: Box::new(tail) }), _lawspec_marker: std::marker::PhantomData }
}

pub fn replicate(value0: ls::BigUint, value1: i8) -> Vec<i8> {
    // The declared input contract bounds this exact count below 64.
    let count: usize = value0.try_into().expect("a bounded replication count");
    let mut result = nil();
    for _ in 0..count {
        result = prepend(value1, result);
    }
    result
}

pub fn append(value0: Vec<i8>, value1: Vec<i8>) -> Vec<i8> {
    match value0 {
        Vec::VNil { .. } => value1,
        Vec::VCons { value, .. } => prepend(value.head, append(*value.tail, value1)),
    }
}

pub fn zip(value0: Vec<i8>, value1: Vec<bool>) -> Vec<bool> {
    match (value0, value1) {
        (Vec::VCons { value: first, .. }, Vec::VCons { value: second, .. }) =>
            prepend(second.head, zip(*first.tail, *second.tail)),
        _ => nil(),
    }
}

pub fn flatten(value0: Tree<i8>) -> Vec<i8> {
    match value0 {
        Tree::Tip { .. } => nil(),
        Tree::Bin { value: payload, .. } => {
            let BinaryNode { left, value, right } = *payload;
            let right = prepend(value, flatten(*right));
            append(flatten(*left), right)
        }
    }
}
