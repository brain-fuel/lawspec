// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Char -> Char)
pub fn echoChar(value0: char) -> char {
    value0
}

// LawSpec: (CodePoint -> CodePoint)
pub fn echoCodePoint(value0: ls::CodePoint) -> ls::CodePoint {
    value0
}

// LawSpec: (CodeUnit16 -> CodeUnit16)
pub fn echoCodeUnit(value0: u16) -> u16 {
    value0
}

// LawSpec: (Bytes -> Bytes)
pub fn echoBytes(value0: Vec<u8>) -> Vec<u8> {
    value0
}

// LawSpec: (Complex64 -> Complex64)
pub fn echoComplex(value0: ls::Complex32) -> ls::Complex32 {
    value0
}

// LawSpec: (Int8 -> BigInt)
pub fn successor(value0: i8) -> ls::BigInt {
    ls::BigInt::from(value0) + 1
}

// LawSpec: (Int8 -> Int8)
pub fn narrow(value0: i8) -> i8 {
    value0
}

// LawSpec: (Decimal -> (Decimal -> Decimal))
pub fn addDecimal(value0: ls::Decimal, value1: ls::Decimal) -> ls::Decimal {
    value0.add(&value1).unwrap()
}

// LawSpec: (Symbol -> (Symbol -> Bool))
pub fn sameSymbol(value0: ls::Symbol, value1: ls::Symbol) -> bool {
    value0 == value1
}

// LawSpec: (Utf16Text -> Utf16Text)
pub fn echoRaw(value0: ls::Utf16Text) -> ls::Utf16Text {
    value0
}

// LawSpec: (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
pub fn echoPresence(value0: ls::Optional<ls::Nullable<i8>>) -> ls::Optional<ls::Nullable<i8>> {
    value0
}

// LawSpec: (Unit -> Unit)
pub fn finish(value0: ()) -> () {
    ()
}

// LawSpec: (UInt64 -> UInt64)
pub fn preserveBig(value0: u64) -> u64 {
    value0
}

// LawSpec: (IntSize -> IntSize)
pub fn machineEcho(value0: isize) -> isize {
    value0
}
