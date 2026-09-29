#![allow(non_snake_case)]
use crate::lawspec_runtime::{BigInt,Integer};
pub fn add(x:BigInt,y:BigInt)->Integer {(x+y).into()}
pub fn multiply(x:BigInt,y:BigInt)->Integer {(x*y).into()}
pub fn negateValue(x:BigInt)->Integer {(-x).into()}
pub fn maximumValue(x:BigInt,y:BigInt)->Integer {x.max(y).into()}
pub fn subtractValue(x:BigInt,y:BigInt)->Integer {(x-y).into()}
pub fn divideLeft(x:BigInt,y:BigInt)->Integer {(x-y).into()}
pub fn divideRight(x:BigInt,y:BigInt)->Integer {(x+y).into()}
