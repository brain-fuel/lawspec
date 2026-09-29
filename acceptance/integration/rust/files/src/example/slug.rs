#![allow(non_snake_case)]
pub fn normalize(x:String)->String {x.replace(" ","-")}
pub fn referenceNormalize(x:String)->String {x.split(' ').collect::<Vec<_>>().join("-")}
