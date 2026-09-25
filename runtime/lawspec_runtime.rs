//! Portable scalar semantics. This source has no dependency on a test framework.
pub use num_bigint::{BigInt, BigUint};
pub use num_complex::{Complex32, Complex64};
pub use num_rational::BigRational;
use num_traits::{FromPrimitive, One, Signed, ToPrimitive, Zero};
use std::collections::HashMap;
use std::sync::Arc;

pub type Result<T> = std::result::Result<T, String>;

/// A logical Integer result accepts any native integer without losing bits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Integer(pub BigInt);
macro_rules! integer_from {
    ($($t:ty),*) => {$ (impl From<$t> for Integer {
        fn from(value: $t) -> Self { Self(BigInt::from(value)) }
    })*};
}
integer_from!(
    i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize, BigInt, BigUint
);

/// Finite base-ten value; arithmetic is independent of ambient rounding modes.
#[derive(Clone, Debug)]
pub struct Decimal {
    pub coefficient: BigInt,
    pub exponent: BigInt,
}
impl Decimal {
    pub fn new(coefficient: BigInt, exponent: BigInt) -> Self {
        Self {
            coefficient,
            exponent,
        }
    }
    pub fn ratio(&self) -> Result<BigRational> {
        let exponent = self
            .exponent
            .abs()
            .to_u32()
            .ok_or("decimal exponent exceeds runtime capacity")?;
        let power = BigInt::from(10u8).pow(exponent);
        Ok(if self.exponent.is_negative() {
            BigRational::new(self.coefficient.clone(), power)
        } else {
            BigRational::from_integer(&self.coefficient * power)
        })
    }
    pub fn from_ratio(value: BigRational) -> Result<Self> {
        let mut denominator = value.denom().clone();
        let mut twos = 0u32;
        let mut fives = 0u32;
        while (&denominator % 2u8).is_zero() {
            denominator /= 2u8;
            twos += 1;
        }
        while (&denominator % 5u8).is_zero() {
            denominator /= 5u8;
            fives += 1;
        }
        if !denominator.is_one() {
            return Err("conversion to Decimal is not finite; use prelude.round".into());
        }
        let scale = twos.max(fives);
        Ok(Self::new(
            value.numer()
                * BigInt::from(2u8).pow(scale - twos)
                * BigInt::from(5u8).pow(scale - fives),
            -BigInt::from(scale),
        ))
    }
    pub fn add(&self, other: &Self) -> Result<Self> {
        Self::from_ratio(self.ratio()? + other.ratio()?)
    }
    pub fn sub(&self, other: &Self) -> Result<Self> {
        Self::from_ratio(self.ratio()? - other.ratio()?)
    }
    pub fn mul(&self, other: &Self) -> Result<Self> {
        Self::from_ratio(self.ratio()? * other.ratio()?)
    }
    pub fn round(value: BigRational, scale: i32) -> Result<Self> {
        let power = BigInt::from(10u8).pow(scale.unsigned_abs());
        let factor = if scale < 0 {
            BigRational::new(BigInt::one(), power)
        } else {
            BigRational::from_integer(power)
        };
        let scaled = &value * &factor;
        let quotient = scaled.numer() / scaled.denom();
        let remainder = scaled.numer() % scaled.denom();
        let twice = remainder.abs() * 2u8;
        let rounded = if twice > *scaled.denom()
            || twice == *scaled.denom() && !(&quotient % 2u8).is_zero()
        {
            quotient
                + if scaled.is_negative() {
                    -BigInt::one()
                } else {
                    BigInt::one()
                }
        } else {
            quotient
        };
        Self::from_ratio(BigRational::from_integer(rounded) / factor)
    }
}
impl PartialEq for Decimal {
    fn eq(&self, other: &Self) -> bool {
        matches!((self.ratio(),other.ratio()), (Ok(a),Ok(b)) if a==b)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodePoint(pub u32);
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodePointText(pub Vec<u32>);
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Utf16Text(pub Vec<u16>);
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Null;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Undefined;
#[derive(Clone, Debug, PartialEq)]
pub enum Nullable<T> {
    Null,
    Present(T),
}
#[derive(Clone, Debug, PartialEq)]
pub enum Optional<T> {
    Undefined,
    Present(T),
}
#[derive(Clone, Debug)]
pub struct Symbol(Arc<String>);
impl Symbol {
    pub fn new(description: String) -> Self {
        Self(Arc::new(description))
    }
    pub fn description(&self) -> &str {
        &self.0
    }
}
impl PartialEq for Symbol {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
impl Eq for Symbol {}
#[derive(Clone, Debug, Default)]
pub struct Context {
    symbols: HashMap<String, Symbol>,
}
impl Context {
    pub fn symbol(&mut self, id: &str, description: &str) -> Symbol {
        self.symbols
            .entry(id.into())
            .or_insert_with(|| Symbol::new(description.into()))
            .clone()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Integer(BigInt),
    Decimal(Decimal),
    Rational(BigRational),
    Float32(f32),
    Float64(f64),
    Complex32(Complex32),
    Complex64(Complex64),
    Bool(bool),
    Char(char),
    CodePoint(u32),
    CodeUnit16(u16),
    Text(String),
    CodePointText(Vec<u32>),
    Utf16Text(Vec<u16>),
    Bytes(Vec<u8>),
    Symbol(Symbol),
    Unit,
    Null,
    Undefined,
    Nullable(Option<Box<Value>>),
    Optional(Option<Box<Value>>),
}
impl Value {
    pub fn exact(&self) -> Result<BigRational> {
        match self {
            Self::Integer(n) => Ok(BigRational::from_integer(n.clone())),
            Self::Decimal(d) => d.ratio(),
            Self::Rational(r) => Ok(r.clone()),
            _ => Err("requires exact number".into()),
        }
    }
    pub fn integer(&self) -> Result<BigInt> {
        let r = self.exact()?;
        if !r.is_integer() {
            return Err("fractional integer conversion".into());
        }
        Ok(r.to_integer())
    }
    pub fn boolean(&self) -> Result<bool> {
        match self {
            Self::Bool(b) => Ok(*b),
            _ => Err("expected Bool".into()),
        }
    }
    fn real64(&self) -> Result<f64> {
        match self {
            Self::Float32(f) => Ok(f64::from(*f)),
            Self::Float64(f) => Ok(*f),
            _ => Ok(f64::from_bits(exact_float_bits(&self.exact()?, false)?)),
        }
    }
    fn complex64(&self) -> Result<Complex64> {
        match self {
            Self::Complex32(c) => Ok(Complex64::new(f64::from(c.re), f64::from(c.im))),
            Self::Complex64(c) => Ok(*c),
            _ => Ok(Complex64::new(self.real64()?, 0.0)),
        }
    }
    pub fn convert(self, target: &str, machine_bits: u32) -> Result<Self> {
        if target == "Float32" {
            // Rational-to-f32 is direct, avoiding double rounding through f64.
            return Ok(Self::Float32(match &self {
                Self::Float32(x) => *x,
                Self::Float64(x) => *x as f32,
                _ => f32::from_bits(exact_float_bits(&self.exact()?, true)? as u32),
            }));
        }
        if target == "Float64" {
            return Ok(Self::Float64(self.real64()?));
        }
        if target == "Complex64" || target == "Complex128" {
            if target == "Complex128" {
                return Ok(Self::Complex64(self.complex64()?));
            }
            let (real, imag) = match self {
                Self::Complex32(c) => return Ok(Self::Complex32(c)),
                Self::Complex64(c) => (Self::Float64(c.re), Self::Float64(c.im)),
                x => (x, Self::Float32(0.0)),
            };
            return Ok(Self::Complex32(Complex32::new(
                f32::from_value(real.convert("Float32", machine_bits)?)?,
                f32::from_value(imag.convert("Float32", machine_bits)?)?,
            )));
        }
        let exact = match self {
            Self::Float32(f) => {
                Self::Rational(BigRational::from_f32(f).ok_or("non-finite exact conversion")?)
            }
            Self::Float64(f) => {
                Self::Rational(BigRational::from_f64(f).ok_or("non-finite exact conversion")?)
            }
            x => x,
        };
        if target == "Decimal" {
            return Ok(Self::Decimal(Decimal::from_ratio(exact.exact()?)?));
        }
        if target == "Rational" {
            return Ok(Self::Rational(exact.exact()?));
        }
        let (signed, width) = match target {
            "Int8" => (true, 8),
            "Int16" => (true, 16),
            "Int32" => (true, 32),
            "Int64" => (true, 64),
            "UInt8" => (false, 8),
            "UInt16" => (false, 16),
            "UInt32" => (false, 32),
            "UInt64" => (false, 64),
            "IntSize" => (true, machine_bits),
            "UIntSize" | "UIntPtr" => (false, machine_bits),
            "Integer" | "BigInt" => return Ok(Self::Integer(exact.integer()?)),
            "BigUInt" => {
                let n = exact.integer()?;
                if n.is_negative() {
                    return Err("BigUInt cannot be negative".into());
                }
                return Ok(Self::Integer(n));
            }
            _ => return Err(format!("unsupported numeric conversion: {target}")),
        };
        let n = exact.integer()?;
        let (lo, hi) = if signed {
            let bound = BigInt::one() << (width - 1);
            (-&bound, &bound - 1u8)
        } else {
            (BigInt::zero(), (BigInt::one() << width) - 1u8)
        };
        if n < lo || n > hi {
            return Err(format!("integer outside {target} range"));
        }
        Ok(Self::Integer(n))
    }
}

/// Round the exact ratio once, directly into an IEEE significand and exponent.
pub fn exact_float_bits(ratio: &BigRational, single: bool) -> Result<u64> {
    let (precision, bias, sign_shift) = if single {
        (24i64, 127i64, 31)
    } else {
        (53i64, 1023i64, 63)
    };
    let sign = u64::from(ratio.is_negative()) << sign_shift;
    if ratio.is_zero() {
        return Ok(sign);
    }
    let n = ratio.numer().abs();
    let d = ratio.denom().clone();
    let mut exponent = n.bits() as i64 - d.bits() as i64;
    if if exponent >= 0 {
        n < (&d << exponent as usize)
    } else {
        (&n << (-exponent) as usize) < d
    } {
        exponent -= 1;
    }
    let infinity = sign | (((2 * bias + 1) as u64) << (precision - 1));
    if exponent > bias {
        return Ok(infinity);
    }
    let minimum = 1 - bias;
    if exponent < minimum - precision {
        return Ok(sign);
    }
    let scale = exponent.max(minimum) - (precision - 1);
    let num = if scale < 0 { n << (-scale) as usize } else { n };
    let den = if scale > 0 { d << scale as usize } else { d };
    let mut q = &num / &den;
    let twice = (&num % &den) * 2u8;
    if twice > den || twice == den && !(&q % 2u8).is_zero() {
        q += 1u8;
    }
    exponent = exponent.max(minimum);
    if q == (BigInt::one() << precision as usize) {
        q >>= 1usize;
        exponent += 1;
    }
    if exponent > bias {
        return Ok(infinity);
    }
    let hidden = 1u64 << (precision - 1);
    let significand = q.to_u64().ok_or("invalid IEEE significand")?;
    let (exp, mantissa) = if significand < hidden {
        (0, significand)
    } else {
        ((exponent + bias) as u64, significand - hidden)
    };
    Ok(sign | (exp << (precision - 1)) | mantissa)
}

fn numeric_class(value: &Value) -> Option<bool> {
    match value {
        Value::Integer(_) | Value::Decimal(_) | Value::Rational(_) => Some(true),
        Value::Float32(_) | Value::Float64(_) | Value::Complex32(_) | Value::Complex64(_) => {
            Some(false)
        }
        _ => None,
    }
}

pub fn equal(a: &Value, b: &Value) -> Result<bool> {
    if let (Some(x), Some(y)) = (numeric_class(a), numeric_class(b)) {
        if x != y {
            return Err("exact/inexact mixing requires an explicit conversion".into());
        }
    }
    match (a, b) {
        (
            Value::Integer(_) | Value::Decimal(_) | Value::Rational(_),
            Value::Integer(_) | Value::Decimal(_) | Value::Rational(_),
        ) => Ok(a.exact()? == b.exact()?),
        (Value::Float32(_) | Value::Float64(_), Value::Float32(_) | Value::Float64(_)) => {
            Ok(a.real64()? == b.real64()?)
        }
        (
            Value::Complex32(_) | Value::Complex64(_) | Value::Float32(_) | Value::Float64(_),
            Value::Complex32(_) | Value::Complex64(_) | Value::Float32(_) | Value::Float64(_),
        ) => Ok(a.complex64()? == b.complex64()?),
        (Value::Nullable(Some(x)), Value::Nullable(Some(y)))
        | (Value::Optional(Some(x)), Value::Optional(Some(y))) => equal(x, y),
        _ => Ok(a == b),
    }
}

/// `domain` is the compiler-resolved arithmetic evidence, never inferred here.
pub fn binary(op: &str, domain: &str, a: Value, b: Value) -> Result<Value> {
    use Value::*;
    if op == "==" || op == "!=" {
        return Ok(Bool(equal(&a, &b)? == (op == "==")));
    }
    let exact_domain = !matches!(domain, "Float32" | "Float64" | "Complex64" | "Complex128");
    if numeric_class(&a) != Some(exact_domain) || numeric_class(&b) != Some(exact_domain) {
        return Err("numeric operands must match the resolved arithmetic domain; use an explicit conversion".into());
    }
    macro_rules! calculate {
        ($x:expr,$y:expr,$variant:ident) => {{
            let x = $x;
            let y = $y;
            match op {
                "+" => Ok($variant(x + y)),
                "-" => Ok($variant(x - y)),
                "*" => Ok($variant(x * y)),
                "/" => Ok($variant(x / y)),
                "<" => Ok(Bool(x < y)),
                "<=" => Ok(Bool(x <= y)),
                ">" => Ok(Bool(x > y)),
                ">=" => Ok(Bool(x >= y)),
                _ => Err("invalid arithmetic operation".into()),
            }
        }};
    }
    if domain == "Float32" {
        return calculate!(
            f32::from_value(a.convert("Float32", 64)?)?,
            f32::from_value(b.convert("Float32", 64)?)?,
            Float32
        );
    }
    if domain == "Float64" {
        return calculate!(a.real64()?, b.real64()?, Float64);
    }
    macro_rules! complex {
        ($x:expr,$y:expr,$variant:ident) => {{
            let x = $x;
            let y = $y;
            match op {
                "+" => Ok($variant(x + y)),
                "-" => Ok($variant(x - y)),
                "*" => Ok($variant(x * y)),
                "/" => {
                    // Match portable componentwise IEEE operations at declared precision.
                    let d = y.re * y.re + y.im * y.im;
                    Ok($variant(num_complex::Complex::new(
                        (x.re * y.re + x.im * y.im) / d,
                        (x.im * y.re - x.re * y.im) / d,
                    )))
                }
                _ => Err("complex values are not ordered".into()),
            }
        }};
    }
    if domain == "Complex64" {
        return complex!(
            num_complex::Complex32::from_value(a.convert("Complex64", 64)?)?,
            num_complex::Complex32::from_value(b.convert("Complex64", 64)?)?,
            Complex32
        );
    }
    if domain == "Complex128" {
        return complex!(a.complex64()?, b.complex64()?, Complex64);
    }
    let x = a.exact()?;
    let y = b.exact()?;
    if matches!(op, "/" | "quot" | "rem") && y.is_zero() {
        return Err("exact division by zero".into());
    }
    let result = match op {
        "+" => x + y,
        "-" => x - y,
        "*" => x * y,
        "/" => x / y,
        "quot" => return Ok(Integer(a.integer()? / b.integer()?)),
        "rem" => return Ok(Integer(a.integer()? % b.integer()?)),
        "<" => return Ok(Bool(x < y)),
        "<=" => return Ok(Bool(x <= y)),
        ">" => return Ok(Bool(x > y)),
        ">=" => return Ok(Bool(x >= y)),
        _ => return Err("invalid arithmetic operation".into()),
    };
    Rational(result).convert(domain, 64)
}

pub fn negate(value: Value) -> Result<Value> {
    Ok(match value {
        Value::Integer(x) => Value::Integer(-x),
        Value::Rational(x) => Value::Rational(-x),
        Value::Decimal(x) => Value::Decimal(Decimal::new(-x.coefficient, x.exponent)),
        Value::Float32(x) => Value::Float32(-x),
        Value::Float64(x) => Value::Float64(-x),
        Value::Complex32(x) => Value::Complex32(-x),
        Value::Complex64(x) => Value::Complex64(-x),
        _ => return Err("negation requires numeric operand".into()),
    })
}

pub trait IntoValue {
    fn into_value(self) -> Value;
}
pub trait FromValue: Sized {
    fn from_value(value: Value) -> Result<Self>;
}
macro_rules! native {
    ($t:ty,$variant:ident) => {
        impl IntoValue for $t {
            fn into_value(self) -> Value {
                Value::$variant(self)
            }
        }
        impl FromValue for $t {
            fn from_value(value: Value) -> Result<Self> {
                if let Value::$variant(x) = value {
                    Ok(x)
                } else {
                    Err(concat!("expected ", stringify!($t)).into())
                }
            }
        }
    };
}
native!(BigInt, Integer);
native!(Decimal, Decimal);
native!(BigRational, Rational);
native!(f32, Float32);
native!(f64, Float64);
native!(Complex32, Complex32);
native!(Complex64, Complex64);
native!(bool, Bool);
native!(char, Char);
native!(String, Text);
native!(Vec<u8>, Bytes);
native!(Symbol, Symbol);
impl IntoValue for Integer {
    fn into_value(self) -> Value {
        Value::Integer(self.0)
    }
}
impl FromValue for Integer {
    fn from_value(value: Value) -> Result<Self> {
        Ok(Self(value.integer()?))
    }
}
impl IntoValue for BigUint {
    fn into_value(self) -> Value {
        Value::Integer(self.into())
    }
}
impl FromValue for BigUint {
    fn from_value(value: Value) -> Result<Self> {
        value
            .integer()?
            .to_biguint()
            .ok_or_else(|| "BigUInt cannot be negative".into())
    }
}
macro_rules! primitive_int {
    ($($t:ty),*) => {$ (
        impl IntoValue for $t { fn into_value(self)->Value { Value::Integer(BigInt::from(self)) } }
        impl FromValue for $t { fn from_value(value:Value)->Result<Self> {
            Self::try_from(value.integer()?).map_err(|_|concat!("integer outside ",stringify!($t)," range").into())
        } }
    )*};
}
primitive_int!(
    i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize
);
macro_rules! raw {
    ($t:ident,$variant:ident,$valid:expr) => {
        impl IntoValue for $t {
            fn into_value(self) -> Value {
                Value::$variant(self.0)
            }
        }
        impl FromValue for $t {
            fn from_value(value: Value) -> Result<Self> {
                match value {
                    Value::$variant(x) if ($valid)(&x) => Ok(Self(x)),
                    _ => Err(concat!("invalid ", stringify!($t)).into()),
                }
            }
        }
    };
}
raw!(CodePoint, CodePoint, |x: &u32| *x <= 0x10ffff);
raw!(CodePointText, CodePointText, |x: &Vec<u32>| x
    .iter()
    .all(|c| *c <= 0x10ffff));
raw!(Utf16Text, Utf16Text, |_: &Vec<u16>| true);
macro_rules! absence {
    ($t:ty,$variant:ident,$value:expr) => {
        impl IntoValue for $t {
            fn into_value(self) -> Value {
                Value::$variant
            }
        }
        impl FromValue for $t {
            fn from_value(value: Value) -> Result<Self> {
                if matches!(value, Value::$variant) {
                    Ok($value)
                } else {
                    Err(concat!("expected ", stringify!($t)).into())
                }
            }
        }
    };
}
absence!((), Unit, ());
absence!(Null, Null, Null);
absence!(Undefined, Undefined, Undefined);
macro_rules! presence {
    ($t:ident,$absent:ident) => {
        impl<T: IntoValue> IntoValue for $t<T> {
            fn into_value(self) -> Value {
                Value::$t(match self {
                    Self::$absent => None,
                    Self::Present(x) => Some(Box::new(x.into_value())),
                })
            }
        }
        impl<T: FromValue> FromValue for $t<T> {
            fn from_value(value: Value) -> Result<Self> {
                match value {
                    Value::$t(None) => Ok(Self::$absent),
                    Value::$t(Some(x)) => Ok(Self::Present(T::from_value(*x)?)),
                    _ => Err("presence type mismatch".into()),
                }
            }
        }
    };
}
presence!(Nullable, Null);
presence!(Optional, Undefined);

pub fn require_architecture(machine_bits: u32) -> Result<()> {
    if usize::BITS == machine_bits {
        Ok(())
    } else {
        Err(format!(
            "machineBits does not match native architecture: profile {machine_bits}, native {}",
            usize::BITS
        ))
    }
}

pub fn helper(name: &str, mut args: Vec<Value>) -> Result<Value> {
    use Value::*;
    if name == "round" && args.len() == 2 {
        let scale = i32::from_value(args.pop().unwrap())?;
        return Ok(Decimal(self::Decimal::round(args[0].exact()?, scale)?));
    }
    if args.len() != 1 {
        return Err(format!("invalid {name} arguments"));
    }
    let value = args.pop().unwrap();
    Ok(match name {
        "checked" => Bool(true),
        "length" => Integer(BigInt::from(match value {
            Text(s) => s.chars().count(),
            CodePointText(s) => s.len(),
            Utf16Text(s) => s.len(),
            Bytes(s) => s.len(),
            _ => return Err("length requires sequence".into()),
        })),
        "isPresent" => Bool(match value {
            Nullable(v) | Optional(v) => v.is_some(),
            _ => return Err("expected presence".into()),
        }),
        "presentValue" => match value {
            Nullable(Some(v)) | Optional(Some(v)) => *v,
            _ => return Err("absent value has no payload".into()),
        },
        "real" => match value {
            Complex32(c) => Float32(c.re),
            Complex64(c) => Float64(c.re),
            _ => return Err("expected complex value".into()),
        },
        "imag" => match value {
            Complex32(c) => Float32(c.im),
            Complex64(c) => Float64(c.im),
            _ => return Err("expected complex value".into()),
        },
        "isNaN" => Bool(value.real64()?.is_nan()),
        "isInfinite" => Bool(value.real64()?.is_infinite()),
        "isFinite" => Bool(value.real64()?.is_finite()),
        "isNegativeZero" => {
            let x = value.real64()?;
            Bool(x == 0.0 && x.is_sign_negative())
        }
        _ => return Err(format!("unknown helper: {name}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn int(n: i64) -> Value {
        Value::Integer(n.into())
    }
    fn decimal(c: i64, e: i64) -> Value {
        Value::Decimal(Decimal::new(c.into(), e.into()))
    }
    #[test]
    fn integer_promotion_and_checked_bridges() {
        let result = binary("+", "Integer", 127i8.into_value(), int(1)).unwrap();
        assert_eq!(result, int(128));
        assert!(i8::from_value(result).is_err());
        assert_eq!(
            u64::from_value(Value::Integer(u64::MAX.into())).unwrap(),
            u64::MAX
        );
        assert_eq!(Integer::from(u128::MAX).0, BigInt::from(u128::MAX));
        assert!(u64::from_value(int(-1)).is_err());
        assert!(i32::from_value(Value::Rational(BigRational::new(1.into(), 2.into()))).is_err());
    }
    #[test]
    fn exact_decimal_and_rational_arithmetic() {
        assert!(
            equal(
                &binary("+", "Decimal", decimal(1, -1), decimal(2, -1)).unwrap(),
                &decimal(3, -1)
            )
            .unwrap()
        );
        let half = binary("/", "Rational", int(1), int(2)).unwrap();
        assert_eq!(half, Value::Rational(BigRational::new(1.into(), 2.into())));
        assert!(binary("/", "Rational", int(1), int(0)).is_err());
        assert!(
            Value::Rational(BigRational::new(1.into(), 3.into()))
                .convert("Decimal", 64)
                .is_err()
        );
        assert_eq!(binary("quot", "Integer", int(-7), int(3)).unwrap(), int(-2));
        assert_eq!(binary("rem", "Integer", int(-7), int(3)).unwrap(), int(-1));
    }
    #[test]
    fn decimal_rounds_half_even_at_requested_scale() {
        for (numerator, expected) in [(125, 12), (135, 14), (-125, -12), (-135, -14)] {
            let d = Decimal::round(BigRational::new(numerator.into(), 100.into()), 1).unwrap();
            assert!(equal(&Value::Decimal(d), &decimal(expected, -1)).unwrap());
        }
        let hundred = Decimal::round(BigRational::from_integer(250.into()), -2).unwrap();
        assert!(equal(&Value::Decimal(hundred), &int(200)).unwrap());
    }
    #[test]
    fn ieee_equality_classification_and_precision() {
        assert!(binary("+", "Float32", int(1), Value::Float32(1.0)).is_err());
        assert!(equal(&int(1), &Value::Float32(1.0)).is_err());
        assert!(!equal(&Value::Float32(f32::NAN), &Value::Float32(f32::NAN)).unwrap());
        assert!(equal(&Value::Float64(0.0), &Value::Float64(-0.0)).unwrap());
        assert_eq!(
            helper("isNegativeZero", vec![Value::Float32(-0.0)]).unwrap(),
            Value::Bool(true)
        );
        assert_eq!(
            binary(
                "+",
                "Float32",
                Value::Float32(16777216.0),
                Value::Float32(1.0)
            )
            .unwrap(),
            Value::Float32(16777216.0)
        );
        assert_eq!(
            binary("/", "Float64", Value::Float64(1.0), Value::Float64(0.0)).unwrap(),
            Value::Float64(f64::INFINITY)
        );
        assert!(
            Value::Float64(f64::INFINITY)
                .convert("Integer", 64)
                .is_err()
        );
        assert_eq!(
            Value::Float64(0.5).convert("Rational", 64).unwrap(),
            Value::Rational(BigRational::new(1.into(), 2.into()))
        );
    }
    #[test]
    fn nested_code_units_cross_native_bridges_without_losing_the_domain() {
        let native: Optional<Nullable<u16>> = Optional::Present(Nullable::Present(0xd800));
        let value = validate(
            native.clone().into_value(),
            "Optional Nullable CodeUnit16",
            64,
        )
        .unwrap();
        assert_eq!(
            value,
            Value::Optional(Some(Box::new(Value::Nullable(Some(Box::new(
                Value::CodeUnit16(0xd800)
            ))))))
        );
        let round_trip = Optional::<Nullable<u16>>::from_value(
            native_value(value, "Optional Nullable CodeUnit16").unwrap(),
        )
        .unwrap();
        assert_eq!(round_trip, native);
        assert!(validate(Value::CodePoint(0x110000), "CodePoint", 64).is_err());
    }
    #[test]
    fn exact_float_conversion_avoids_double_rounding() {
        let n = BigInt::parse_bytes(b"1208925891672223212634113", 10).unwrap();
        let d = BigInt::parse_bytes(b"1208925819614629174706176", 10).unwrap();
        assert_eq!(
            exact_float_bits(&BigRational::new(n, d), true).unwrap(),
            0x3f800001
        );
        assert_eq!(
            exact_float_bits(&BigRational::new(16777217.into(), 16777216.into()), true).unwrap(),
            0x3f800000
        );
        assert_eq!(
            exact_float_bits(&BigRational::new(1.into(), BigInt::one() << 150usize), true).unwrap(),
            0
        );
        assert_eq!(
            exact_float_bits(
                &BigRational::new((-1).into(), BigInt::one() << 150usize),
                true
            )
            .unwrap(),
            0x80000000
        );
        assert_eq!(
            exact_float_bits(
                &BigRational::from_integer(BigInt::one() << 1024usize),
                false
            )
            .unwrap(),
            f64::INFINITY.to_bits()
        );
    }
    #[test]
    fn raw_text_symbols_and_nested_presence_remain_distinct() {
        let raw = Utf16Text(vec![0xd800, 0, 0xdc00]);
        assert_eq!(
            Utf16Text::from_value(raw.clone().into_value()).unwrap(),
            raw
        );
        assert!(CodePoint::from_value(Value::CodePoint(0xd800)).is_ok());
        assert!(CodePoint::from_value(Value::CodePoint(0x110000)).is_err());
        let mut context = Context::default();
        assert_eq!(context.symbol("a", "same"), context.symbol("a", "same"));
        assert_ne!(context.symbol("a", "same"), context.symbol("b", "same"));
        let absent: Optional<Nullable<i8>> = Optional::Undefined;
        let null: Optional<Nullable<i8>> = Optional::Present(Nullable::Null);
        let some: Optional<Nullable<i8>> = Optional::Present(Nullable::Present(0));
        assert_ne!(absent.clone().into_value(), null.clone().into_value());
        assert_ne!(null.clone().into_value(), some.clone().into_value());
        for x in [absent, null, some] {
            assert_eq!(
                Optional::<Nullable<i8>>::from_value(x.clone().into_value()).unwrap(),
                x
            );
        }
    }
}

pub fn validate(value: Value, name: &str, bits: u32) -> Result<Value> {
    if let Some(inner) = name.strip_prefix("Nullable ") {
        return match value {
            Value::Nullable(None) => Ok(Value::Nullable(None)),
            Value::Nullable(Some(x)) => {
                Ok(Value::Nullable(Some(Box::new(validate(*x, inner, bits)?))))
            }
            _ => Err("expected Nullable".into()),
        };
    }
    if let Some(inner) = name.strip_prefix("Optional ") {
        return match value {
            Value::Optional(None) => Ok(Value::Optional(None)),
            Value::Optional(Some(x)) => {
                Ok(Value::Optional(Some(Box::new(validate(*x, inner, bits)?))))
            }
            _ => Err("expected Optional".into()),
        };
    }
    if name == "CodeUnit16" {
        return match value {
            Value::CodeUnit16(x) => Ok(Value::CodeUnit16(x)),
            x => Ok(Value::CodeUnit16(u16::from_value(x)?)),
        };
    }
    let valid = match (&value, name) {
        (Value::Integer(_), _) => return value.convert(name, bits),
        (Value::Decimal(d), "Decimal") => {
            d.ratio()?;
            true
        }
        (Value::Rational(_), "Rational")
        | (Value::Float32(_), "Float32")
        | (Value::Float64(_), "Float64")
        | (Value::Complex32(_), "Complex64")
        | (Value::Complex64(_), "Complex128")
        | (Value::Bool(_), "Bool")
        | (Value::Char(_), "Char")
        | (Value::CodeUnit16(_), "CodeUnit16")
        | (Value::Text(_), "Text")
        | (Value::Bytes(_), "Bytes")
        | (Value::Utf16Text(_), "Utf16Text")
        | (Value::Symbol(_), "Symbol")
        | (Value::Unit, "Unit")
        | (Value::Null, "Null")
        | (Value::Undefined, "Undefined") => true,
        (Value::CodePoint(c), "CodePoint") => *c <= 0x10ffff,
        (Value::CodePointText(cs), "CodePointText") => cs.iter().all(|c| *c <= 0x10ffff),
        _ => false,
    };
    if valid {
        Ok(value)
    } else {
        Err(format!("invalid {name} representation returned by adapter"))
    }
}

/// Type-directed native bridge for nested domains that share a Rust primitive.
pub fn native_value(value: Value, name: &str) -> Result<Value> {
    if let Some(inner) = name.strip_prefix("Nullable ") {
        return match value {
            Value::Nullable(Some(x)) => {
                Ok(Value::Nullable(Some(Box::new(native_value(*x, inner)?))))
            }
            Value::Nullable(None) => Ok(Value::Nullable(None)),
            _ => Err("expected Nullable".into()),
        };
    }
    if let Some(inner) = name.strip_prefix("Optional ") {
        return match value {
            Value::Optional(Some(x)) => {
                Ok(Value::Optional(Some(Box::new(native_value(*x, inner)?))))
            }
            Value::Optional(None) => Ok(Value::Optional(None)),
            _ => Err("expected Optional".into()),
        };
    }
    match (value, name) {
        (Value::CodeUnit16(x), "CodeUnit16") => Ok(Value::Integer(x.into())),
        (v, _) => Ok(v),
    }
}
