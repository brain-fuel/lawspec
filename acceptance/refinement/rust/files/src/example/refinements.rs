#![allow(non_snake_case)]
use crate::lawspec_runtime as ls;
pub fn add(a:i8,b:i8)->ls::Integer {(i16::from(a)+i16::from(b)).into()}
pub fn successor(a:i8)->ls::Integer {(i16::from(a)+1).into()}
pub fn count(a:String)->ls::Integer {a.chars().count().into()}
pub fn preserve(a:u64)->ls::Integer {a.into()}
pub fn positive(a:i8)->i8 {a}
pub fn abstractEcho(a:ls::BigInt)->ls::Integer {a.into()}
