#![allow(non_snake_case)]
use crate::lawspec_runtime::{BigInt,Integer};
pub fn sumFour(a:BigInt,b:BigInt,c:BigInt,d:BigInt)->Integer {(a+b+c+d).into()}
pub fn format(prefix:String,enabled:bool,port:i32,suffix:String)->String {prefix+&if enabled {port.to_string()} else {String::new()}+&suffix}
pub fn referenceFormat(prefix:String,enabled:bool,port:i32,suffix:String)->String {[prefix,if enabled {port.to_string()} else {String::new()},suffix].concat()}
pub fn trim(x:String)->String {x.trim().to_owned()}
