// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_runtime as ls;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub fn dedupe(value0: Vec<i32>) -> BTreeSet<i32> {
    value0.into_iter().collect()
}

pub fn wordCounts(value0: Vec<String>) -> BTreeMap<String, ls::BigInt> {
    let mut counts = BTreeMap::new();
    for word in value0 {
        *counts.entry(word).or_insert_with(|| ls::BigInt::from(0)) += 1;
    }
    counts
}

pub fn fifo(value0: Vec<i8>) -> VecDeque<i8> {
    value0.into_iter().collect()
}

// A Stack is a Vec whose top is last, as for push and pop.
pub fn lifo(value0: Vec<i8>) -> Vec<i8> {
    value0
}

pub fn rotate(value0: VecDeque<i8>) -> VecDeque<i8> {
    let mut rotated = value0;
    rotated.rotate_left(if rotated.is_empty() { 0 } else { 1 });
    rotated
}

pub fn distinctRows(value0: Vec<Vec<i8>>) -> BTreeSet<Vec<i8>> {
    value0.into_iter().collect()
}
