// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Char -> Char)
pub fn echoChar(value0: char) -> char {
    todo!("example.scalar_adapters::echoChar")
}

// LawSpec: (CodePoint -> CodePoint)
pub fn echoCodePoint(value0: ls::CodePoint) -> ls::CodePoint {
    todo!("example.scalar_adapters::echoCodePoint")
}

// LawSpec: (CodeUnit16 -> CodeUnit16)
pub fn echoCodeUnit(value0: u16) -> u16 {
    todo!("example.scalar_adapters::echoCodeUnit")
}

// LawSpec: (Bytes -> Bytes)
pub fn echoBytes(value0: Vec<u8>) -> Vec<u8> {
    todo!("example.scalar_adapters::echoBytes")
}

// LawSpec: (Complex64 -> Complex64)
pub fn echoComplex(value0: ls::Complex32) -> ls::Complex32 {
    todo!("example.scalar_adapters::echoComplex")
}

// LawSpec: (Int8 -> BigInt)
pub fn successor(value0: i8) -> ls::BigInt {
    todo!("example.scalar_adapters::successor")
}

// LawSpec: (Int8 -> Int8)
pub fn narrow(value0: i8) -> i8 {
    todo!("example.scalar_adapters::narrow")
}

// LawSpec: (Decimal -> (Decimal -> Decimal))
pub fn addDecimal(value0: ls::Decimal, value1: ls::Decimal) -> ls::Decimal {
    todo!("example.scalar_adapters::addDecimal")
}

// LawSpec: (Symbol -> (Symbol -> Bool))
pub fn sameSymbol(value0: ls::Symbol, value1: ls::Symbol) -> bool {
    todo!("example.scalar_adapters::sameSymbol")
}

// LawSpec: (Utf16Text -> Utf16Text)
pub fn echoRaw(value0: ls::Utf16Text) -> ls::Utf16Text {
    todo!("example.scalar_adapters::echoRaw")
}

// LawSpec: (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
pub fn echoPresence(value0: ls::Optional<ls::Nullable<i8>>) -> ls::Optional<ls::Nullable<i8>> {
    todo!("example.scalar_adapters::echoPresence")
}

// LawSpec: (Unit -> Unit)
pub fn finish(value0: ()) -> () {
    todo!("example.scalar_adapters::finish")
}

// LawSpec: (UInt64 -> UInt64)
pub fn preserveBig(value0: u64) -> u64 {
    todo!("example.scalar_adapters::preserveBig")
}

// LawSpec: (IntSize -> IntSize)
pub fn machineEcho(value0: isize) -> isize {
    todo!("example.scalar_adapters::machineEcho")
}
