//// Native values for portable scalars that BEAM cannot represent directly.
//// All arithmetic and checked conversion use the shared exact runtime.
//// ref:DEC-portable-exact-arithmetic ref:DEC-idiomatic-generated-types

pub type Float32
pub type Float64
pub type Complex64
pub type Complex128
pub type Rational
pub type Decimal
pub type Symbol

pub type Null {
  Null
}

pub type Undefined {
  Undefined
}

pub type Optional(a) {
  Absent
  Present(a)
}

pub type Nullable(a) {
  NullValue
  NonNull(a)
}
