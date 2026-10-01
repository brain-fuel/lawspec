//! Portable scalar semantics. This source has no dependency on a test framework.
pub use num_bigint::{BigInt, BigUint};
pub use num_complex::{Complex32, Complex64};
pub use num_rational::BigRational;
use num_traits::{FromPrimitive, One, Signed, ToPrimitive, Zero};
use std::collections::HashMap;
use std::sync::Arc;

pub type Result<T> = std::result::Result<T, String>;

/// Runs a generated test on a thread with a large stack: generated values of
/// deep data, in debug builds, can exceed the default test thread's stack.
pub fn with_stack<T: Send + 'static>(body: impl FnOnce() -> T + Send + 'static) -> T {
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(body)
        .expect("test thread")
        .join()
        .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
}

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
    List(Vec<Value>),
    Maybe(Option<Box<Value>>),
    Left(Box<Value>),
    Right(Box<Value>),
    // The compiler supplies unit-qualified constructor identities. Payloads are
    // checked by the generated typed bridges, preserving nested sum states.
    Data(String, Vec<Value>),
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
        | (Value::Optional(Some(x)), Value::Optional(Some(y)))
        | (Value::Maybe(Some(x)), Value::Maybe(Some(y)))
        | (Value::Left(x), Value::Left(y))
        | (Value::Right(x), Value::Right(y)) => equal(x, y),
        (Value::Data(left_tag, _), Value::Data(right_tag, _)) if left_tag != right_tag => Ok(false),
        (Value::List(xs), Value::List(ys)) | (Value::Data(_, xs), Value::Data(_, ys)) => {
            if xs.len() != ys.len() {
                return Ok(false);
            }
            for (x, y) in xs.iter().zip(ys) {
                if !equal(x, y)? {
                    return Ok(false);
                }
            }
            Ok(true)
        }
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
        "pow" => {
            let exponent = b.integer()?;
            if exponent.is_negative() {
                return Err("negative exponent".into());
            }
            let exponent = exponent.to_u32().ok_or_else(|| "exponent too large".to_string())?;
            return Ok(Integer(num_traits::Pow::pow(a.integer()?, exponent)));
        }
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

/// Algebraic Either is independent of interoperability absence wrappers.
#[derive(Clone, Debug, PartialEq)]
pub enum Either<L, R> {
    Left(L),
    Right(R),
}
impl<T: IntoValue> IntoValue for Box<T> {
    fn into_value(self) -> Value {
        (*self).into_value()
    }
}
impl<T: FromValue> FromValue for Box<T> {
    fn from_value(value: Value) -> Result<Self> {
        T::from_value(value).map(Box::new)
    }
}
impl<T: IntoValue> IntoValue for Vec<T> {
    fn into_value(self) -> Value {
        Value::List(self.into_iter().map(IntoValue::into_value).collect())
    }
}
impl<T: FromValue> FromValue for Vec<T> {
    fn from_value(value: Value) -> Result<Self> {
        let values = match value {
            Value::List(values) => values,
            Value::Bytes(values) => values
                .into_iter()
                .map(|v| Value::Integer(v.into()))
                .collect(),
            _ => return Err("expected List or Bytes".into()),
        };
        values.into_iter().map(T::from_value).collect()
    }
}
impl<T: IntoValue> IntoValue for Option<T> {
    fn into_value(self) -> Value {
        Value::Maybe(self.map(|x| Box::new(x.into_value())))
    }
}
impl<T: FromValue> FromValue for Option<T> {
    fn from_value(value: Value) -> Result<Self> {
        match value {
            Value::Maybe(value) => value.map(|x| T::from_value(*x)).transpose(),
            _ => Err("expected Maybe".into()),
        }
    }
}
impl<L: IntoValue, R: IntoValue> IntoValue for Either<L, R> {
    fn into_value(self) -> Value {
        match self {
            Self::Left(x) => Value::Left(Box::new(x.into_value())),
            Self::Right(x) => Value::Right(Box::new(x.into_value())),
        }
    }
}
impl<L: FromValue, R: FromValue> FromValue for Either<L, R> {
    fn from_value(value: Value) -> Result<Self> {
        match value {
            Value::Left(x) => Ok(Self::Left(L::from_value(*x)?)),
            Value::Right(x) => Ok(Self::Right(R::from_value(*x)?)),
            _ => Err("expected Either".into()),
        }
    }
}

// A GADT case's existential fields hold checked dynamic values.
impl IntoValue for Value {
    fn into_value(self) -> Value {
        self
    }
}
impl FromValue for Value {
    fn from_value(value: Value) -> Result<Self> {
        Ok(value)
    }
}

/// A fully applied type, or a parameter in a constructor's field schema.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TypeRef {
    Named(&'static str, Vec<TypeRef>),
    Parameter(usize),
}

impl TypeRef {
    pub fn named(name: &'static str, arguments: Vec<TypeRef>) -> Self {
        Self::Named(name, arguments)
    }

    /// Expression runtime spelling, after schema type arguments are substituted.
    pub fn expression_key(&self) -> Result<String> {
        match self {
            Self::Parameter(index) => Err(format!("unbound expression type parameter {index}")),
            Self::Named(name, arguments) => {
                let mut parts = vec![(*name).to_owned()];
                for argument in arguments {
                    parts.push(argument.expression_key()?);
                }
                Ok(parts.join(" "))
            }
        }
    }

    pub fn instantiate(&self, arguments: &[TypeRef]) -> Result<Self> {
        match self {
            Self::Parameter(index) => arguments
                .get(*index)
                .cloned()
                .ok_or_else(|| format!("unbound data type parameter {index}")),
            Self::Named(name, fields) => Ok(Self::Named(
                name,
                fields
                    .iter()
                    .map(|field| field.instantiate(arguments))
                    .collect::<Result<_>>()?,
            )),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ConstructorSchema {
    pub tag: &'static str,
    pub fields: Vec<TypeRef>,
}

#[derive(Clone, Debug)]
pub struct DataSchema {
    pub name: &'static str,
    pub parameters: usize,
    pub constructors: Vec<ConstructorSchema>,
}

/// Typed constructor predicates receive instantiated type arguments and logical
/// fields. A false result rejects a candidate; an error is an evaluation failure.
pub type FieldPredicate = fn(&Schema, &[TypeRef], &[Value], u32, &mut Context) -> Result<bool>;

#[derive(Clone, Debug)]
pub struct ConstructorContract {
    pub tag: &'static str,
    pub predicates: Vec<FieldPredicate>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ValueCheck {
    Accepted(Value),
    Rejected(String),
}

#[derive(Debug)]
enum ValidationFailure {
    Rejected(String),
    Error(String),
}

impl ValidationFailure {
    fn context(self, prefix: String) -> Self {
        match self {
            Self::Rejected(message) => Self::Rejected(format!("{prefix}: {message}")),
            Self::Error(message) => Self::Error(format!("{prefix}: {message}")),
        }
    }

    fn message(self) -> String {
        match self {
            Self::Rejected(message) | Self::Error(message) => message,
        }
    }
}

impl From<String> for ValidationFailure {
    fn from(message: String) -> Self {
        Self::Error(message)
    }
}

/// Compiler-provided data definitions. Validation is framework-independent and
/// follows instantiated field types, rather than guessing from Rust payloads.
#[derive(Clone, Debug)]
pub struct Schema {
    definitions: HashMap<&'static str, DataSchema>,
    contracts: HashMap<&'static str, Vec<FieldPredicate>>,
    // Indexed families: per constructor, index terms then guards, in prefix
    // notation over field indices. Validation checks the guards.
    indices: HashMap<&'static str, &'static [&'static str]>,
    // GADT constructors: refinements fixing parameters to patterns, and the
    // number of existentials (parameters numbered after the definition's own).
    refinements: HashMap<&'static str, (Vec<(usize, TypeRef)>, usize)>,
}

/// A GADT constructor's refinements and existential count, by tag.
pub type Refinements = Vec<(&'static str, Vec<(usize, TypeRef)>, usize)>;

/// A prefix index term: `c<n>`, `f<field>[.<index>]` or an operator.
enum SchemaIndexTerm {
    Constant(BigInt),
    Field(usize, usize),
    Apply(&'static str, Box<SchemaIndexTerm>, Box<SchemaIndexTerm>),
}

fn parse_schema_index(tokens: &[&'static str], at: &mut usize) -> Result<SchemaIndexTerm> {
    let token = *tokens.get(*at).ok_or("malformed index term")?;
    *at += 1;
    if let Some(digits) = token.strip_prefix('c') {
        return Ok(SchemaIndexTerm::Constant(
            digits.parse().map_err(|_| "malformed index term".to_string())?,
        ));
    }
    if let Some(reference) = token.strip_prefix('f') {
        let mut parts = reference.splitn(2, '.');
        let position = parts.next().unwrap_or("").parse().map_err(|_| "malformed index term".to_string())?;
        let index = match parts.next() {
            Some(index) => index.parse().map_err(|_| "malformed index term".to_string())?,
            None => 0,
        };
        return Ok(SchemaIndexTerm::Field(position, index));
    }
    let left = parse_schema_index(tokens, at)?;
    let right = parse_schema_index(tokens, at)?;
    Ok(SchemaIndexTerm::Apply(token, Box::new(left), Box::new(right)))
}

/// Natural index arithmetic; `None` when an operation has no natural value.
fn eval_schema_index(
    term: &SchemaIndexTerm,
    field: &mut dyn FnMut(usize, usize) -> Result<BigInt>,
) -> Result<Option<BigInt>> {
    Ok(match term {
        SchemaIndexTerm::Constant(value) => Some(value.clone()),
        SchemaIndexTerm::Field(position, index) => Some(field(*position, *index)?),
        SchemaIndexTerm::Apply(op, left, right) => {
            let (Some(x), Some(y)) = (eval_schema_index(left, field)?, eval_schema_index(right, field)?) else {
                return Ok(None);
            };
            match *op {
                "+" => Some(x + y),
                "-" => (x >= y).then(|| x - y),
                "*" => Some(x * y),
                "div" => (y.is_positive()).then(|| x / y),
                "mod" => (y.is_positive()).then(|| x % y),
                "^" => y.to_u32().filter(|e| *e <= 64).map(|e| num_traits::Pow::pow(x, e)),
                _ => return Err("malformed index term".into()),
            }
        }
    })
}

fn is_index_guard(text: &str) -> bool {
    text.starts_with("== ") || text.starts_with(">= ")
}

fn builtin_arity(name: &str) -> Option<usize> {
    match name {
        "List" | "Maybe" | "Nullable" | "Optional" => Some(1),
        "Either" => Some(2),
        "Bool" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16" | "UInt32"
        | "UInt64" | "IntSize" | "UIntSize" | "UIntPtr" | "Integer" | "BigInt" | "BigUInt"
        | "Decimal" | "Rational" | "Float32" | "Float64" | "Complex64" | "Complex128" | "Char"
        | "CodePoint" | "CodeUnit16" | "Text" | "CodePointText" | "Utf16Text" | "Bytes"
        | "Symbol" | "Unit" | "Null" | "Undefined" => Some(0),
        _ => None,
    }
}

// Recipes describe parameter positions rather than instantiated field types.
#[derive(Clone, Debug)]
enum PayloadPlan {
    Ignore,
    Parameter(usize),
    Applied(&'static str, Vec<PayloadPlan>),
}

impl PayloadPlan {
    fn field(ty: &TypeRef, arguments: &[Self]) -> Result<Self> {
        match ty {
            TypeRef::Parameter(index) => arguments
                .get(*index)
                .cloned()
                .ok_or_else(|| "unbound payload parameter".into()),
            TypeRef::Named(name, fields) => {
                let children = fields
                    .iter()
                    .map(|field| Self::field(field, arguments))
                    .collect::<Result<Vec<_>>>()?;
                Ok(
                    if children.iter().all(|child| matches!(child, Self::Ignore)) {
                        Self::Ignore
                    } else {
                        Self::Applied(name, children)
                    },
                )
            }
        }
    }
}

impl Schema {
    pub fn has_contracts(&self) -> bool {
        self.contracts
            .values()
            .any(|predicates| !predicates.is_empty())
    }

    pub fn new(definitions: Vec<DataSchema>) -> Result<Self> {
        Self::with_contracts(definitions, vec![])
    }

    /// Attach indexed families' index terms and guards, keyed by constructor.
    pub fn with_indices(mut self, indices: &[(&'static str, &'static [&'static str])]) -> Self {
        self.indices.extend(indices.iter().copied());
        self
    }

    /// The index of a checked value, computed from its constructor's term.
    fn index_of(&self, ty: &TypeRef, value: &Value, index: usize) -> Result<BigInt> {
        let (TypeRef::Named(name, arguments), Value::Data(tag, fields)) = (ty, value) else {
            return Err("no index for this value".into());
        };
        let definition = self.definitions.get(name).ok_or("no index for this type")?;
        let constructor = definition
            .constructors
            .iter()
            .find(|constructor| constructor.tag == tag)
            .ok_or("unknown constructor")?;
        let texts = self.indices.get(constructor.tag).copied().unwrap_or(&[]);
        let text = texts
            .iter()
            .filter(|text| !is_index_guard(text))
            .nth(index)
            .ok_or_else(|| format!("no index for {name}"))?;
        let tokens: Vec<&'static str> = text.split(' ').collect();
        let term = parse_schema_index(&tokens, &mut 0)?;
        let mut field = |position: usize, child: usize| -> Result<BigInt> {
            let field_type = constructor.fields.get(position).ok_or("malformed index term")?.instantiate(arguments)?;
            self.index_of(&field_type, &fields[position], child)
        };
        eval_schema_index(&term, &mut field)?.ok_or_else(|| format!("index of {tag} has no natural value"))
    }

    pub fn with_contracts(
        definitions: Vec<DataSchema>,
        contracts: Vec<ConstructorContract>,
    ) -> Result<Self> {
        Self::with_refinements(definitions, contracts, vec![])
    }

    pub fn with_refinements(
        definitions: Vec<DataSchema>,
        contracts: Vec<ConstructorContract>,
        refinements: Refinements,
    ) -> Result<Self> {
        let mut types = HashMap::new();
        let mut tags = std::collections::HashSet::new();
        for definition in definitions {
            let name = definition.name;
            if builtin_arity(name).is_some() || types.contains_key(name) {
                return Err(format!("duplicate or reserved data type: {name}"));
            }
            for constructor in &definition.constructors {
                if !tags.insert(constructor.tag) {
                    return Err(format!("duplicate constructor: {}", constructor.tag));
                }
            }
            types.insert(name, definition);
        }
        let mut predicates = HashMap::new();
        for contract in contracts {
            if !tags.contains(contract.tag) {
                return Err(format!("unknown constructor contract: {}", contract.tag));
            }
            if predicates
                .insert(contract.tag, contract.predicates)
                .is_some()
            {
                return Err(format!("duplicate constructor contract: {}", contract.tag));
            }
        }
        let schema = Self {
            definitions: types,
            contracts: predicates,
            indices: HashMap::new(),
            refinements: refinements
                .into_iter()
                .map(|(tag, patterns, existentials)| (tag, (patterns, existentials)))
                .collect(),
        };
        for definition in schema.definitions.values() {
            for constructor in &definition.constructors {
                let existentials = schema.refinements.get(constructor.tag).map_or(0, |(_, count)| *count);
                for field in &constructor.fields {
                    schema.check_type(field, definition.parameters + existentials)?;
                }
            }
        }
        Ok(schema)
    }

    fn check_type(&self, ty: &TypeRef, parameters: usize) -> Result<()> {
        match ty {
            TypeRef::Parameter(index) if *index < parameters => Ok(()),
            TypeRef::Parameter(index) => Err(format!("unbound data type parameter {index}")),
            TypeRef::Named(name, arguments) => {
                let arity = builtin_arity(name)
                    .or_else(|| self.definitions.get(name).map(|d| d.parameters))
                    .ok_or_else(|| format!("unknown data type: {name}"))?;
                if arity != arguments.len() {
                    return Err(format!("expected {arity} type arguments for {name}"));
                }
                for argument in arguments {
                    self.check_type(argument, parameters)?;
                }
                Ok(())
            }
        }
    }

    /// Instantiated fields for composing native generators. None denotes a
    /// built-in type; an empty list denotes a user type with no constructors.
    pub fn constructor_fields(&self, ty: &TypeRef) -> Result<Option<Vec<ConstructorSchema>>> {
        self.check_type(ty, 0)?;
        let TypeRef::Named(name, arguments) = ty else {
            return Err("uninstantiated generator type".into());
        };
        self.definitions
            .get(name)
            .map(|definition| {
                definition
                    .constructors
                    .iter()
                    // A GADT constructor whose refinements do not match these
                    // arguments builds no value of this type.
                    .filter_map(|constructor| {
                        self.refine(constructor, arguments, definition.parameters)
                            .map(|extended| (constructor, extended))
                    })
                    .map(|(constructor, extended)| {
                        Ok(ConstructorSchema {
                            tag: constructor.tag,
                            fields: constructor
                                .fields
                                .iter()
                                .map(|field| field.instantiate(&extended))
                                .collect::<Result<_>>()?,
                        })
                    })
                    .collect::<Result<_>>()
            })
            .transpose()
    }

    /// Arguments extended with the existentials a constructor's refinements
    /// bind; None when the refinements do not match.
    fn refine(&self, constructor: &ConstructorSchema, arguments: &[TypeRef], parameters: usize) -> Option<Vec<TypeRef>> {
        let Some((patterns, existentials)) = self.refinements.get(constructor.tag) else {
            return Some(arguments.to_vec());
        };
        fn matches(
            pattern: &TypeRef,
            actual: &TypeRef,
            arguments: &[TypeRef],
            parameters: usize,
            bound: &mut HashMap<usize, TypeRef>,
        ) -> bool {
            match (pattern, actual) {
                (TypeRef::Parameter(index), _) if *index < parameters => arguments.get(*index) == Some(actual),
                (TypeRef::Parameter(index), _) => bound.entry(*index).or_insert_with(|| actual.clone()) == actual,
                (TypeRef::Named(name, children), TypeRef::Named(other, values)) => {
                    name == other
                        && children.len() == values.len()
                        && children.iter().zip(values).all(|(child, value)| matches(child, value, arguments, parameters, bound))
                }
                _ => false,
            }
        }
        let mut bound = HashMap::new();
        for (index, pattern) in patterns {
            if !matches(pattern, arguments.get(*index)?, arguments, parameters, &mut bound) {
                return None;
            }
        }
        let mut extended = arguments.to_vec();
        for k in 0..*existentials {
            extended.push(bound.get(&(parameters + k))?.clone());
        }
        Some(extended)
    }

    /// Validate first, then check only stored occurrences of type arguments.
    /// The dispatcher shares one mutable context without aliasing callback borrows.
    pub fn all_payloads_with_context(
        &self,
        value: Value,
        ty: &TypeRef,
        predicate_count: usize,
        bits: u32,
        context: &mut Context,
        mut predicate: impl FnMut(usize, Value, &mut Context) -> Result<Value>,
    ) -> Result<Value> {
        self.check_type(ty, 0)?;
        let TypeRef::Named(name, arguments) = ty else {
            return Err("payload predicates require an instantiated data type".into());
        };
        if !self.definitions.contains_key(name)
            && !matches!(*name, "List" | "Maybe" | "Either" | "Nullable" | "Optional")
        {
            return Err("payload predicates require a data type".into());
        }
        if arguments.len() != predicate_count {
            return Err("payload predicate arity mismatch".into());
        }
        let checked = self.validate_with_context(value, ty, bits, context)?;
        let plan = PayloadPlan::Applied(
            name,
            (0..predicate_count).map(PayloadPlan::Parameter).collect(),
        );
        self.walk_payload(&plan, checked, context, &mut predicate)
            .map(Value::Bool)
    }

    fn walk_payload(
        &self,
        plan: &PayloadPlan,
        value: Value,
        context: &mut Context,
        predicate: &mut impl FnMut(usize, Value, &mut Context) -> Result<Value>,
    ) -> Result<bool> {
        let (name, arguments) = match plan {
            PayloadPlan::Ignore => return Ok(true),
            PayloadPlan::Parameter(index) => return predicate(*index, value, context)?.boolean(),
            PayloadPlan::Applied(name, arguments) => (*name, arguments),
        };
        match (name, value) {
            ("List", Value::List(values)) => {
                for (index, value) in values.into_iter().enumerate() {
                    if !self
                        .walk_payload(&arguments[0], value, context, predicate)
                        .map_err(|error| format!("List element {index}: {error}"))?
                    {
                        return Ok(false);
                    }
                }
                Ok(true)
            }
            ("Maybe", Value::Maybe(value))
            | ("Nullable", Value::Nullable(value))
            | ("Optional", Value::Optional(value)) => match value {
                None => Ok(true),
                Some(value) => self
                    .walk_payload(&arguments[0], *value, context, predicate)
                    .map_err(|error| format!("{name} payload: {error}")),
            },
            ("Either", Value::Left(value)) => self
                .walk_payload(&arguments[0], *value, context, predicate)
                .map_err(|error| format!("Either Left payload: {error}")),
            ("Either", Value::Right(value)) => self
                .walk_payload(&arguments[1], *value, context, predicate)
                .map_err(|error| format!("Either Right payload: {error}")),
            (_, Value::Data(tag, values)) => {
                let definition = self
                    .definitions
                    .get(name)
                    .ok_or_else(|| format!("unknown payload data type: {name}"))?;
                let constructor = definition
                    .constructors
                    .iter()
                    .find(|item| item.tag == tag)
                    .ok_or_else(|| format!("unknown payload constructor: {tag}"))?;
                for (index, (field, value)) in constructor.fields.iter().zip(values).enumerate() {
                    let plan = PayloadPlan::field(field, arguments)?;
                    if !self
                        .walk_payload(&plan, value, context, predicate)
                        .map_err(|error| format!("{tag} field {index}: {error}"))?
                    {
                        return Ok(false);
                    }
                }
                Ok(true)
            }
            _ => Err("payload traversal requires a matching structural value".into()),
        }
    }

    pub fn validate(&self, value: Value, ty: &TypeRef, bits: u32) -> Result<Value> {
        self.validate_with_context(value, ty, bits, &mut Context::default())
    }

    pub fn check_with_context(
        &self,
        value: Value,
        ty: &TypeRef,
        bits: u32,
        context: &mut Context,
    ) -> Result<ValueCheck> {
        self.check_type(ty, 0)?;
        if !matches!(bits, 32 | 64) {
            return Err("machineBits must be 32 or 64".into());
        }
        match self.walk(value, ty, bits, false, context) {
            Ok(value) => Ok(ValueCheck::Accepted(value)),
            Err(ValidationFailure::Rejected(message)) => Ok(ValueCheck::Rejected(message)),
            Err(ValidationFailure::Error(message)) => Err(message),
        }
    }

    pub fn validate_with_context(
        &self,
        value: Value,
        ty: &TypeRef,
        bits: u32,
        context: &mut Context,
    ) -> Result<Value> {
        match self.check_with_context(value, ty, bits, context)? {
            ValueCheck::Accepted(value) => Ok(value),
            ValueCheck::Rejected(message) => Err(message),
        }
    }

    /// Check logical fields before adapting raw code units to native integers.
    pub fn native_value(&self, value: Value, ty: &TypeRef, bits: u32) -> Result<Value> {
        self.native_value_with_context(value, ty, bits, &mut Context::default())
    }

    pub fn native_value_with_context(
        &self,
        value: Value,
        ty: &TypeRef,
        bits: u32,
        context: &mut Context,
    ) -> Result<Value> {
        let checked = self.validate_with_context(value, ty, bits, context)?;
        self.walk(checked, ty, bits, true, context)
            .map_err(ValidationFailure::message)
    }

    fn walk(
        &self,
        value: Value,
        ty: &TypeRef,
        bits: u32,
        native: bool,
        context: &mut Context,
    ) -> std::result::Result<Value, ValidationFailure> {
        let TypeRef::Named(name, arguments) = ty else {
            return Err("uninstantiated data type parameter".to_string().into());
        };
        if let Some(definition) = self.definitions.get(name) {
            let Value::Data(tag, fields) = value else {
                return Err(format!("expected data value of type {name}").into());
            };
            let constructor = definition
                .constructors
                .iter()
                .find(|constructor| constructor.tag == tag)
                .ok_or_else(|| format!("constructor {tag} does not belong to {name}"))?;
            if fields.len() != constructor.fields.len() {
                return Err(format!("wrong field count for {tag}").into());
            }
            let arguments = &self
                .refine(constructor, arguments, definition.parameters)
                .ok_or_else(|| format!("constructor {tag} is not a value of {name}"))?;
            let checked: Vec<Value> = fields
                .into_iter()
                .zip(&constructor.fields)
                .enumerate()
                .map(|(index, (field, field_type))| {
                    self.walk(
                        field,
                        &field_type.instantiate(arguments)?,
                        bits,
                        native,
                        context,
                    )
                    .map_err(|error| error.context(format!("{tag} field {index}")))
                })
                .collect::<std::result::Result<_, ValidationFailure>>()?;
            if !native {
                if let Some(predicates) = self.contracts.get(constructor.tag) {
                    for (index, predicate) in predicates.iter().enumerate() {
                        let label = format!("{tag}: field refinement {}", index + 1);
                        let accepted = predicate(self, arguments, &checked, bits, context)
                            .map_err(|message| {
                                ValidationFailure::Error(format!("{label}: {message}"))
                            })?;
                        if !accepted {
                            return Err(ValidationFailure::Rejected(format!("{label} failed")));
                        }
                    }
                }
                for text in self.indices.get(constructor.tag).copied().unwrap_or(&[]) {
                    if !is_index_guard(text) {
                        continue;
                    }
                    let tokens: Vec<&'static str> = text.split(' ').collect();
                    let mut at = 1;
                    let left = parse_schema_index(&tokens, &mut at)?;
                    let right = parse_schema_index(&tokens, &mut at)?;
                    let mut field = |position: usize, child: usize| -> Result<BigInt> {
                        let field_type = constructor.fields.get(position).ok_or("malformed index term")?.instantiate(arguments)?;
                        self.index_of(&field_type, &checked[position], child)
                    };
                    let x = eval_schema_index(&left, &mut field)?;
                    let y = eval_schema_index(&right, &mut field)?;
                    let holds = match (x, y) {
                        (Some(x), Some(y)) => if tokens[0] == "==" { x == y } else { x >= y },
                        _ => false,
                    };
                    if !holds {
                        return Err(ValidationFailure::Rejected(format!("{tag}: index guard {text} failed")));
                    }
                }
            }
            return Ok(Value::Data(tag, checked));
        }
        if arguments.is_empty() {
            let checked = validate(value, name, bits)?;
            return if native {
                native_value(checked, name).map_err(ValidationFailure::Error)
            } else {
                Ok(checked)
            };
        }
        match (*name, arguments.as_slice(), value) {
            ("List", [element], Value::List(values)) => Ok(Value::List(
                values
                    .into_iter()
                    .enumerate()
                    .map(|(index, value)| {
                        self.walk(value, element, bits, native, context)
                            .map_err(|error| error.context(format!("List element {index}")))
                    })
                    .collect::<std::result::Result<_, ValidationFailure>>()?,
            )),
            ("Maybe", [element], Value::Maybe(value)) => Ok(Value::Maybe(
                value
                    .map(|value| {
                        self.walk(*value, element, bits, native, context)
                            .map(Box::new)
                    })
                    .transpose()?,
            )),
            ("Nullable", [element], Value::Nullable(value)) => Ok(Value::Nullable(
                value
                    .map(|value| {
                        self.walk(*value, element, bits, native, context)
                            .map(Box::new)
                    })
                    .transpose()?,
            )),
            ("Optional", [element], Value::Optional(value)) => Ok(Value::Optional(
                value
                    .map(|value| {
                        self.walk(*value, element, bits, native, context)
                            .map(Box::new)
                    })
                    .transpose()?,
            )),
            ("Either", [left, _], Value::Left(value)) => Ok(Value::Left(Box::new(
                self.walk(*value, left, bits, native, context)?,
            ))),
            ("Either", [_, right], Value::Right(value)) => Ok(Value::Right(Box::new(
                self.walk(*value, right, bits, native, context)?,
            ))),
            _ => Err(format!("invalid value for {name}").into()),
        }
    }
}

/// Build a user constructor selected and typed by the compiler. This does not
/// validate its payload; generated bridges check each field at native boundaries.
pub fn construct_data(tag: &str, fields: Vec<Value>) -> Value {
    Value::Data(tag.into(), fields)
}

/// Extract exactly one constructor's fields before typed field conversion.
/// Tag and arity checks prevent cross-constructor coercion and dropped fields.
pub fn data_fields(value: Value, tag: &str, arity: usize) -> Result<Vec<Value>> {
    match value {
        Value::Data(actual, fields) if actual == tag && fields.len() == arity => Ok(fields),
        Value::Data(actual, fields) => Err(format!(
            "expected {tag} with {arity} fields, found {actual} with {} fields",
            fields.len()
        )),
        _ => Err(format!("expected data constructor {tag}")),
    }
}

pub fn all_elements(
    value: Value,
    mut predicate: impl FnMut(Value) -> Result<Value>,
) -> Result<Value> {
    let Value::List(values) = value else {
        return Err("expected List in element predicate".into());
    };
    for (index, item) in values.into_iter().enumerate() {
        let accepted = predicate(item)
            .and_then(|result| result.boolean())
            .map_err(|error| format!("List element {index}: {error}"))?;
        if !accepted {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

pub fn construct(tag: &str, mut fields: Vec<Value>) -> Result<Value> {
    Ok(match (tag, fields.len()) {
        ("List::Nil", 0) => Value::List(vec![]),
        ("List::Cons", 2) => {
            let Value::List(mut tail) = fields.pop().unwrap() else {
                return Err("expected List tail".into());
            };
            tail.insert(0, fields.pop().unwrap());
            Value::List(tail)
        }
        ("Maybe::Nothing", 0) => Value::Maybe(None),
        ("Maybe::Just", 1) => Value::Maybe(Some(Box::new(fields.pop().unwrap()))),
        ("Either::Left", 1) => Value::Left(Box::new(fields.pop().unwrap())),
        ("Either::Right", 1) => Value::Right(Box::new(fields.pop().unwrap())),
        _ => return Err(format!("invalid constructor or arity: {tag}")),
    })
}

// Read one saturated type from the compiler's prefix encoding. Both arguments
// of Either may themselves contain binary and unary type constructors.
fn split_type(input: &str) -> Result<(&str, &str)> {
    let (head, mut remaining) = input.split_once(' ').unwrap_or((input, ""));
    if head.is_empty() {
        return Err("missing type argument".into());
    }
    let arity = match head {
        "Either" => 2,
        "List" | "Maybe" | "Nullable" | "Optional" => 1,
        _ => 0,
    };
    for _ in 0..arity {
        remaining = split_type(remaining)?.1;
    }
    Ok((input[..input.len() - remaining.len()].trim_end(), remaining))
}
pub fn either_types(arguments: &str) -> Result<(&str, &str)> {
    let (left, rest) = split_type(arguments)?;
    let (right, extra) = split_type(rest)?;
    if !extra.is_empty() {
        return Err("extra Either type arguments".into());
    }
    Ok((left, right))
}

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
            List(s) => s.len(),
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
    fn data_bridges_check_constructor_identity_arity_and_typed_fields() {
        let tag = "example::type::Pair::Pair";
        let value = construct_data(tag, vec![int(127), Value::Bool(true)]);
        let fields = data_fields(value.clone(), tag, 2).unwrap();
        assert_eq!(i8::from_value(fields[0].clone()).unwrap(), 127);
        assert!(data_fields(value.clone(), "other::type::Pair::Pair", 2).is_err());
        assert!(data_fields(value.clone(), tag, 1).is_err());
        assert!(data_fields(value, tag, 3).is_err());
        assert!(data_fields(Value::List(vec![]), tag, 0).is_err());
        let overflow = data_fields(construct_data(tag, vec![int(128)]), tag, 1).unwrap();
        assert!(i8::from_value(overflow[0].clone()).is_err());
    }

    #[test]
    fn data_equality_preserves_ieee_and_constructor_semantics() {
        let tag = "example::type::Box::Box";
        let boxed = |value| construct_data(tag, vec![value]);
        let nan = boxed(Value::List(vec![Value::Float32(f32::NAN)]));
        assert!(!equal(&nan, &nan).unwrap());
        assert!(equal(&boxed(Value::Float64(-0.0)), &boxed(Value::Float64(0.0))).unwrap());
        assert!(!equal(&boxed(int(1)), &construct_data(tag, vec![int(1), int(2)])).unwrap());
        assert!(
            !equal(
                &boxed(int(1)),
                &construct_data("example::type::Other::Box", vec![int(1)])
            )
            .unwrap()
        );
        assert!(equal(&boxed(int(1)), &boxed(Value::Float64(1.0))).is_err());
    }

    #[test]
    fn nested_data_keeps_absence_raw_units_and_symbol_identity() {
        let tag = "example::type::Record::Record";
        let symbol = Symbol::new("same description".into());
        let record = |symbol| {
            construct_data(
                tag,
                vec![
                    Value::Maybe(Some(Box::new(Value::Maybe(None)))),
                    Value::Utf16Text(vec![0xd800, 0, 0xdfff]),
                    Value::Bytes(vec![0, 0xff]),
                    Value::Symbol(symbol),
                ],
            )
        };
        let original = record(symbol.clone());
        assert!(equal(&original, &record(symbol)).unwrap());
        assert!(!equal(&original, &record(Symbol::new("same description".into()))).unwrap());
        let mut fields = data_fields(original.clone(), tag, 4).unwrap();
        fields[0] = Value::Maybe(None);
        assert!(!equal(&original, &construct_data(tag, fields)).unwrap());
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
    if let Some(inner) = name.strip_prefix("List ") {
        return match value {
            Value::List(values) => Ok(Value::List(
                values
                    .into_iter()
                    .map(|x| validate(x, inner, bits))
                    .collect::<Result<_>>()?,
            )),
            _ => Err("expected List".into()),
        };
    }
    if let Some(inner) = name.strip_prefix("Maybe ") {
        return match value {
            Value::Maybe(value) => Ok(Value::Maybe(
                value
                    .map(|x| validate(*x, inner, bits).map(Box::new))
                    .transpose()?,
            )),
            _ => Err("expected Maybe".into()),
        };
    }
    if let Some(arguments) = name.strip_prefix("Either ") {
        let (left, right) = either_types(arguments)?;
        return match value {
            Value::Left(x) => Ok(Value::Left(Box::new(validate(*x, left, bits)?))),
            Value::Right(x) => Ok(Value::Right(Box::new(validate(*x, right, bits)?))),
            _ => Err("expected Either".into()),
        };
    }
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
    if name == "Bytes" {
        if let Value::List(values) = value {
            return Ok(Value::Bytes(
                values
                    .into_iter()
                    .map(u8::from_value)
                    .collect::<Result<_>>()?,
            ));
        }
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
    if let Some(inner) = name.strip_prefix("List ") {
        return match value {
            Value::List(values) => Ok(Value::List(
                values
                    .into_iter()
                    .map(|x| native_value(x, inner))
                    .collect::<Result<_>>()?,
            )),
            _ => Err("expected List".into()),
        };
    }
    if let Some(inner) = name.strip_prefix("Maybe ") {
        return match value {
            Value::Maybe(value) => Ok(Value::Maybe(
                value
                    .map(|x| native_value(*x, inner).map(Box::new))
                    .transpose()?,
            )),
            _ => Err("expected Maybe".into()),
        };
    }
    if let Some(arguments) = name.strip_prefix("Either ") {
        let (left, right) = either_types(arguments)?;
        return match value {
            Value::Left(x) => Ok(Value::Left(Box::new(native_value(*x, left)?))),
            Value::Right(x) => Ok(Value::Right(Box::new(native_value(*x, right)?))),
            _ => Err("expected Either".into()),
        };
    }
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

#[cfg(test)]
mod collection_tests {
    use super::*;

    #[test]
    fn nested_collections_preserve_code_units_and_bytes() {
        let native: Vec<Option<Either<u16, Vec<u8>>>> = vec![
            None,
            Some(Either::Left(0xd800)),
            Some(Either::Right(vec![0, 255])),
        ];
        let domain = "List Maybe Either CodeUnit16 Bytes";
        let value = validate(native.clone().into_value(), domain, 64).unwrap();
        let Value::List(ref items) = value else {
            panic!("expected List");
        };
        assert_eq!(items[0], Value::Maybe(None));
        assert_eq!(
            items[1],
            Value::Maybe(Some(Box::new(Value::Left(Box::new(Value::CodeUnit16(
                0xd800
            ))))))
        );
        assert_eq!(
            items[2],
            Value::Maybe(Some(Box::new(Value::Right(Box::new(Value::Bytes(vec![
                0, 255
            ]))))))
        );
        let actual =
            Vec::<Option<Either<u16, Vec<u8>>>>::from_value(native_value(value, domain).unwrap())
                .unwrap();
        assert_eq!(actual, native);
    }

    #[test]
    fn structural_equality_preserves_tags_ieee_rules_and_length() {
        let nan = Value::List(vec![Value::Float32(f32::NAN)]);
        assert!(!equal(&nan, &nan).unwrap());
        assert!(
            equal(
                &Value::List(vec![Value::Float64(-0.0)]),
                &Value::List(vec![Value::Float64(0.0)])
            )
            .unwrap()
        );
        assert!(
            !equal(
                &Value::Left(Box::new(Value::Bool(true))),
                &Value::Right(Box::new(Value::Bool(true)))
            )
            .unwrap()
        );
        assert!(!equal(&Value::List(vec![]), &Value::List(vec![Value::Unit])).unwrap());
        assert!(
            !equal(
                &Value::Maybe(None),
                &Value::Maybe(Some(Box::new(Value::Maybe(None))))
            )
            .unwrap()
        );
    }

    #[test]
    fn collection_domains_reject_bad_payloads_and_do_not_collapse_presence() {
        assert!(
            validate(
                Value::List(vec![Value::Integer(128.into())]),
                "List Int8",
                64
            )
            .is_err()
        );
        assert!(validate(Value::Nullable(None), "Maybe Bool", 64).is_err());
        assert!(validate(Value::Maybe(None), "Nullable Bool", 64).is_err());
        assert!(
            validate(
                Value::Left(Box::new(Value::Bool(true))),
                "Either Int8 Bool",
                64
            )
            .is_err()
        );
        assert!(construct("List::Cons", vec![Value::Bool(true), Value::Bool(false)]).is_err());
        assert_eq!(
            validate(vec![0u8, 255].into_value(), "Bytes", 64).unwrap(),
            Value::Bytes(vec![0, 255])
        );
        assert!(matches!(
            validate(vec![0u8, 255].into_value(), "List UInt8", 64).unwrap(),
            Value::List(_)
        ));
        assert_eq!(
            either_types("Either Bool Unit List Maybe Int8").unwrap(),
            ("Either Bool Unit", "List Maybe Int8")
        );
    }
}

#[cfg(test)]
mod schema_tests {
    use super::*;

    fn ty(name: &'static str) -> TypeRef {
        TypeRef::named(name, vec![])
    }

    fn box_type(element: TypeRef) -> TypeRef {
        TypeRef::named("example::Box", vec![element])
    }

    fn schema() -> Schema {
        Schema::new(vec![
            DataSchema {
                name: "example::Box",
                parameters: 1,
                constructors: vec![ConstructorSchema {
                    tag: "example::Box::Box",
                    fields: vec![TypeRef::Parameter(0)],
                }],
            },
            DataSchema {
                name: "example::Tree",
                parameters: 1,
                constructors: vec![
                    ConstructorSchema {
                        tag: "example::Tree::Leaf",
                        fields: vec![TypeRef::Parameter(0)],
                    },
                    ConstructorSchema {
                        tag: "example::Tree::Branch",
                        fields: vec![TypeRef::named(
                            "List",
                            vec![TypeRef::named("example::Tree", vec![TypeRef::Parameter(0)])],
                        )],
                    },
                ],
            },
        ])
        .unwrap()
    }

    #[test]
    fn validates_recursive_instantiated_fields_and_reports_the_payload_path() {
        let schema = schema();
        let tree = TypeRef::named("example::Tree", vec![ty("Int8")]);
        let value = |integer: i64| {
            construct_data(
                "example::Tree::Branch",
                vec![Value::List(vec![construct_data(
                    "example::Tree::Leaf",
                    vec![Value::Integer(integer.into())],
                )])],
            )
        };
        assert_eq!(schema.validate(value(127), &tree, 64).unwrap(), value(127));
        let error = schema.validate(value(128), &tree, 64).unwrap_err();
        assert!(error.contains("example::Tree::Branch field 0"));
        assert!(error.contains("List element 0"));
        assert!(error.contains("example::Tree::Leaf field 0"));
        assert!(
            schema
                .validate(
                    construct_data("example::Box::Box", vec![Value::Integer(1.into())]),
                    &tree,
                    64,
                )
                .is_err()
        );
        assert!(
            schema
                .validate(construct_data("example::Tree::Leaf", vec![]), &tree, 64)
                .is_err()
        );
    }

    #[test]
    fn preserves_nested_raw_domains_across_native_bridges() {
        let schema = schema();
        let element = box_type(ty("CodeUnit16"));
        let logical = TypeRef::named("Maybe", vec![TypeRef::named("List", vec![element])]);
        let value = Value::Maybe(Some(Box::new(Value::List(vec![construct_data(
            "example::Box::Box",
            vec![Value::CodeUnit16(0xd800)],
        )]))));
        let native = schema.native_value(value.clone(), &logical, 64).unwrap();
        assert_ne!(value, native);
        assert_eq!(schema.validate(native, &logical, 64).unwrap(), value);
        let bytes = box_type(ty("Bytes"));
        let native_bytes = construct_data("example::Box::Box", vec![vec![0u8, 255u8].into_value()]);
        assert_eq!(
            schema.validate(native_bytes, &bytes, 64).unwrap(),
            construct_data("example::Box::Box", vec![Value::Bytes(vec![0, 255])])
        );
        assert!(schema.validate(Value::Maybe(None), &logical, 64).is_ok());
    }

    #[test]
    fn checks_machine_width_and_scalar_domains_inside_user_values() {
        let schema = schema();
        let value = construct_data(
            "example::Box::Box",
            vec![Value::Integer((1u64 << 32).into())],
        );
        let target = box_type(ty("UIntSize"));
        assert!(schema.validate(value.clone(), &target, 32).is_err());
        assert!(schema.validate(value.clone(), &target, 64).is_ok());
        assert!(schema.validate(value.clone(), &target, 16).is_err());
        assert!(schema.native_value(value, &target, 16).is_err());
        assert!(
            schema
                .validate(
                    construct_data("example::Box::Box", vec![Value::Float32(1.0)]),
                    &box_type(ty("Int8")),
                    64,
                )
                .is_err()
        );
    }

    #[test]
    fn rejects_corrupt_schemas_and_unapplied_types() {
        let definition = |name, field| DataSchema {
            name,
            parameters: 1,
            constructors: vec![ConstructorSchema {
                tag: "unique::Tag",
                fields: vec![field],
            }],
        };
        assert!(Schema::new(vec![definition("Bad", TypeRef::Parameter(1))]).is_err());
        assert!(Schema::new(vec![definition("Bad", ty("Unknown"))]).is_err());
        assert!(Schema::new(vec![definition("Bad", ty("Maybe"))]).is_err());
        assert!(Schema::new(vec![definition("Bool", TypeRef::Parameter(0))]).is_err());
        assert!(
            Schema::new(vec![
                definition("First", TypeRef::Parameter(0)),
                definition("Second", TypeRef::Parameter(0)),
            ])
            .is_err()
        );
        let schema = schema();
        let value = construct_data("example::Box::Box", vec![Value::Bool(true)]);
        assert!(
            schema
                .validate(value.clone(), &ty("example::Box"), 64)
                .is_err()
        );
        assert!(schema.validate(value, &TypeRef::Parameter(0), 64).is_err());
    }
}

#[cfg(test)]
mod constructor_contract_tests {
    use super::*;

    fn ty(name: &'static str) -> TypeRef {
        TypeRef::named(name, vec![])
    }

    fn schema(predicates: Vec<FieldPredicate>, element: &'static str) -> Schema {
        Schema::with_contracts(
            vec![DataSchema {
                name: "Box",
                parameters: 1,
                constructors: vec![ConstructorSchema {
                    tag: "Box::Box",
                    fields: vec![TypeRef::Parameter(0)],
                }],
            }],
            vec![ConstructorContract {
                tag: "Box::Box",
                predicates,
            }],
        )
        .and_then(|schema| {
            schema.check_type(&TypeRef::named("Box", vec![ty(element)]), 0)?;
            Ok(schema)
        })
        .unwrap()
    }

    fn value(field: Value) -> Value {
        construct_data("Box::Box", vec![field])
    }

    fn positive(
        _: &Schema,
        arguments: &[TypeRef],
        fields: &[Value],
        bits: u32,
        _: &mut Context,
    ) -> Result<bool> {
        assert_eq!(arguments, &[ty("IntSize")]);
        assert!(matches!(bits, 32 | 64));
        let [Value::Integer(n)] = fields else {
            return Err("expected logical integer".into());
        };
        Ok(n > &BigInt::zero())
    }

    #[test]
    fn contracts_check_native_and_logical_boundaries_at_both_widths() {
        let schema = schema(vec![positive], "IntSize");
        let ty = TypeRef::named("Box", vec![ty("IntSize")]);
        for bits in [32, 64] {
            let good = value(Value::Integer(1.into()));
            let bad = value(Value::Integer(0.into()));
            assert_eq!(schema.validate(good.clone(), &ty, bits).unwrap(), good);
            assert_eq!(schema.native_value(good.clone(), &ty, bits).unwrap(), good);
            assert!(schema.validate(bad.clone(), &ty, bits).is_err());
            assert!(schema.native_value(bad.clone(), &ty, bits).is_err());
            assert!(matches!(
                schema
                    .check_with_context(bad, &ty, bits, &mut Context::default())
                    .unwrap(),
                ValueCheck::Rejected(_)
            ));
        }
        let large = value(Value::Integer(BigInt::from(1u64 << 40)));
        assert!(schema.validate(large.clone(), &ty, 32).is_err());
        assert!(schema.validate(large, &ty, 64).is_ok());
    }

    #[test]
    fn predicates_short_circuit_and_do_not_hide_evaluator_errors() {
        fn reject(_: &Schema, _: &[TypeRef], _: &[Value], _: u32, _: &mut Context) -> Result<bool> {
            Ok(false)
        }
        fn broken(_: &Schema, _: &[TypeRef], _: &[Value], _: u32, _: &mut Context) -> Result<bool> {
            Err("broken predicate".into())
        }
        let ty = TypeRef::named("Box", vec![ty("Bool")]);
        let good = value(Value::Bool(true));
        assert!(matches!(
            schema(vec![reject, broken], "Bool")
                .check_with_context(good.clone(), &ty, 64, &mut Context::default())
                .unwrap(),
            ValueCheck::Rejected(_)
        ));
        let error = schema(vec![broken], "Bool")
            .check_with_context(good, &ty, 64, &mut Context::default())
            .unwrap_err();
        assert!(error.contains("field refinement 1: broken predicate"));
        assert!(
            schema(vec![reject], "Bool")
                .check_with_context(
                    value(Value::Text("wrong".into())),
                    &ty,
                    64,
                    &mut Context::default()
                )
                .is_err()
        );
    }

    #[test]
    fn native_code_unit_conversion_follows_contract_validation() {
        fn surrogate(
            _: &Schema,
            _: &[TypeRef],
            fields: &[Value],
            _: u32,
            _: &mut Context,
        ) -> Result<bool> {
            match fields {
                [Value::CodeUnit16(value)] => Ok(*value == 0xd800),
                _ => Err("predicate must receive a logical code unit".into()),
            }
        }
        let schema = schema(vec![surrogate], "CodeUnit16");
        let ty = TypeRef::named("Box", vec![ty("CodeUnit16")]);
        let logical = value(Value::CodeUnit16(0xd800));
        let native = schema.native_value(logical.clone(), &ty, 64).unwrap();
        assert_eq!(native, value(Value::Integer(0xd800.into())));
        assert_eq!(schema.validate(native, &ty, 64).unwrap(), logical);
        assert!(
            schema
                .native_value(value(Value::CodeUnit16(0)), &ty, 64)
                .is_err()
        );
    }

    #[test]
    fn nested_symbols_share_context_and_keep_rejection_paths() {
        fn fixture(
            _: &Schema,
            _: &[TypeRef],
            fields: &[Value],
            _: u32,
            context: &mut Context,
        ) -> Result<bool> {
            equal(
                &fields[0],
                &Value::Symbol(context.symbol("fixture", "same")),
            )
        }
        let schema = schema(vec![fixture], "Symbol");
        let mut context = Context::default();
        let box_type = TypeRef::named("Box", vec![ty("Symbol")]);
        let expected = value(Value::Symbol(context.symbol("fixture", "same")));
        let cases = vec![
            (
                TypeRef::named("List", vec![box_type.clone()]),
                Value::List(vec![expected.clone()]),
            ),
            (
                TypeRef::named("Maybe", vec![box_type.clone()]),
                Value::Maybe(Some(Box::new(expected.clone()))),
            ),
            (
                TypeRef::named("Nullable", vec![box_type.clone()]),
                Value::Nullable(Some(Box::new(expected.clone()))),
            ),
            (
                TypeRef::named("Optional", vec![box_type.clone()]),
                Value::Optional(Some(Box::new(expected.clone()))),
            ),
            (
                TypeRef::named("Either", vec![box_type.clone(), box_type.clone()]),
                Value::Right(Box::new(expected.clone())),
            ),
        ];
        for (ty, logical) in cases {
            let native = schema
                .native_value_with_context(logical.clone(), &ty, 64, &mut context)
                .unwrap();
            let restored = schema
                .validate_with_context(native, &ty, 64, &mut context)
                .unwrap();
            assert!(equal(&logical, &restored).unwrap());
            assert!(matches!(
                schema
                    .check_with_context(logical, &ty, 64, &mut Context::default())
                    .unwrap(),
                ValueCheck::Rejected(_)
            ));
        }
        let list = TypeRef::named("List", vec![box_type.clone()]);
        let outcome = schema
            .check_with_context(
                Value::List(vec![expected]),
                &list,
                64,
                &mut Context::default(),
            )
            .unwrap();
        let ValueCheck::Rejected(message) = outcome else {
            panic!("expected rejection")
        };
        assert!(message.contains("List element 0"));
        assert!(matches!(
            schema
                .check_with_context(
                    value(Value::Symbol(Symbol::new("same".into()))),
                    &box_type,
                    64,
                    &mut context
                )
                .unwrap(),
            ValueCheck::Rejected(_)
        ));
    }

    #[test]
    fn contract_metadata_rejects_unknown_and_duplicate_constructor_tags() {
        assert!(
            Schema::with_contracts(
                vec![],
                vec![ConstructorContract {
                    tag: "Unknown",
                    predicates: vec![positive],
                }]
            )
            .is_err()
        );
        let definitions = vec![DataSchema {
            name: "Box",
            parameters: 0,
            constructors: vec![ConstructorSchema {
                tag: "Box",
                fields: vec![],
            }],
        }];
        assert!(
            Schema::with_contracts(
                definitions,
                vec![
                    ConstructorContract {
                        tag: "Box",
                        predicates: vec![]
                    },
                    ConstructorContract {
                        tag: "Box",
                        predicates: vec![]
                    },
                ]
            )
            .is_err()
        );
    }
}
