// Scaffolded by LawSpec from scalar_adapters.lawspec. User-owned; never overwritten.
use crate::lawspec_runtime as ls;

// echoChar — scalar_adapters.lawspec:2
// LawSpec type: Char -> Char
#[allow(non_snake_case)]
pub fn echoChar(value0: char) -> char {
    todo!("example.scalar_adapters::echoChar")
}

// echoCodePoint — scalar_adapters.lawspec:3
// LawSpec type: CodePoint -> CodePoint
#[allow(non_snake_case)]
pub fn echoCodePoint(value0: ls::CodePoint) -> ls::CodePoint {
    todo!("example.scalar_adapters::echoCodePoint")
}

// echoCodeUnit — scalar_adapters.lawspec:4
// LawSpec type: CodeUnit16 -> CodeUnit16
#[allow(non_snake_case)]
pub fn echoCodeUnit(value0: u16) -> u16 {
    todo!("example.scalar_adapters::echoCodeUnit")
}

// echoBytes — scalar_adapters.lawspec:5
// LawSpec type: Bytes -> Bytes
#[allow(non_snake_case)]
pub fn echoBytes(value0: Vec<u8>) -> Vec<u8> {
    todo!("example.scalar_adapters::echoBytes")
}

// echoComplex — scalar_adapters.lawspec:6
// LawSpec type: Complex64 -> Complex64
#[allow(non_snake_case)]
pub fn echoComplex(value0: ls::Complex32) -> ls::Complex32 {
    todo!("example.scalar_adapters::echoComplex")
}

// successor — scalar_adapters.lawspec:7
// LawSpec type: Int8 -> Integer
pub fn successor(value0: i8) -> ls::Integer {
    todo!("example.scalar_adapters::successor")
}

// narrow — scalar_adapters.lawspec:8
// LawSpec type: Int8 -> Int8
pub fn narrow(value0: i8) -> i8 {
    todo!("example.scalar_adapters::narrow")
}

// addDecimal — scalar_adapters.lawspec:9
// LawSpec type: Decimal -> (Decimal -> Decimal)
#[allow(non_snake_case)]
pub fn addDecimal(value0: ls::Decimal, value1: ls::Decimal) -> ls::Decimal {
    todo!("example.scalar_adapters::addDecimal")
}

// sameSymbol — scalar_adapters.lawspec:10
// LawSpec type: Symbol -> (Symbol -> Bool)
#[allow(non_snake_case)]
pub fn sameSymbol(value0: ls::Symbol, value1: ls::Symbol) -> bool {
    todo!("example.scalar_adapters::sameSymbol")
}

// echoRaw — scalar_adapters.lawspec:11
// LawSpec type: Utf16Text -> Utf16Text
#[allow(non_snake_case)]
pub fn echoRaw(value0: ls::Utf16Text) -> ls::Utf16Text {
    todo!("example.scalar_adapters::echoRaw")
}

// echoPresence — scalar_adapters.lawspec:12
// LawSpec type: Optional (Nullable (Int8)) -> Optional (Nullable (Int8))
#[allow(non_snake_case)]
pub fn echoPresence(value0: ls::Optional<ls::Nullable<i8>>) -> ls::Optional<ls::Nullable<i8>> {
    todo!("example.scalar_adapters::echoPresence")
}

// finish — scalar_adapters.lawspec:13
// LawSpec type: Unit -> Unit
pub fn finish(value0: ()) -> () {
    todo!("example.scalar_adapters::finish")
}

// preserveBig — scalar_adapters.lawspec:14
// LawSpec type: UInt64 -> UInt64
#[allow(non_snake_case)]
pub fn preserveBig(value0: u64) -> u64 {
    todo!("example.scalar_adapters::preserveBig")
}

// machineEcho — scalar_adapters.lawspec:15
// LawSpec type: IntSize -> IntSize
#[allow(non_snake_case)]
pub fn machineEcho(value0: isize) -> isize {
    todo!("example.scalar_adapters::machineEcho")
}
