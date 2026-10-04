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
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
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
// Decimals compare by value, so 1.0 and 1.00 are one key.
impl Eq for Decimal {}
impl PartialOrd for Decimal {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Decimal {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self.ratio(), other.ratio()) {
            (Ok(a), Ok(b)) => a.cmp(&b),
            _ => (&self.coefficient, &self.exponent).cmp(&(&other.coefficient, &other.exponent)),
        }
    }
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

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct CodePoint(pub u32);
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct CodePointText(pub Vec<u32>);
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Utf16Text(pub Vec<u16>);
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Null;
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Undefined;
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Nullable<T> {
    Null,
    Present(T),
}
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
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
    /// The workflow runtime this call runs under; None is the default one.
    pub workflow: Option<Arc<std::sync::Mutex<WorkflowRuntime>>>,
}
impl Context {
    /// A context whose workflows run under the given runtime.
    pub fn with_workflow(runtime: WorkflowRuntime) -> Context {
        Context { workflow: Some(Arc::new(std::sync::Mutex::new(runtime))), ..Context::default() }
    }
    /// A context for a generated test: workflows wait on a virtual clock, and
    /// gates are off (a workflow law calls the workflow and its composition,
    /// which would see each other's state).
    pub fn testing() -> Context {
        let mut runtime = WorkflowRuntime::new(Box::new(VirtualClock::default()), 0);
        runtime.gates = false;
        Context::with_workflow(runtime)
    }
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
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
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
            // A Stack, whose top is last natively.
            value @ Value::Data(..) => collection_items(value)?,
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

/// Substitute known types, leaving open parameters in place.
fn substitute_open(ty: &TypeRef, known: &[TypeRef]) -> Result<TypeRef> {
    Ok(match ty {
        TypeRef::Parameter(index) => known.get(*index).cloned().unwrap_or(TypeRef::Parameter(*index)),
        TypeRef::Named(name, arguments) => TypeRef::Named(
            name,
            arguments.iter().map(|argument| substitute_open(argument, known)).collect::<Result<_>>()?,
        ),
    })
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
    // Existentials only a value determines (parameter numbers), by tag; their
    // types travel as the trailing Text witness fields.
    witnesses: HashMap<&'static str, &'static [usize]>,
}

/// Types a generator may choose for an existential that only a value fixes.
pub fn witness_pool() -> Vec<TypeRef> {
    vec![TypeRef::Named("Bool", vec![]), TypeRef::Named("Int32", vec![])]
}

/// A witness spells a type as its name, or a parenthesized application.
pub fn witness_key(ty: &TypeRef) -> String {
    match ty {
        TypeRef::Named(name, arguments) if arguments.is_empty() => (*name).to_owned(),
        TypeRef::Named(name, arguments) => {
            let mut parts = vec![(*name).to_owned()];
            parts.extend(arguments.iter().map(witness_key));
            format!("({})", parts.join(" "))
        }
        TypeRef::Parameter(index) => format!("?{index}"),
    }
}

/// Reads a witness key back into a type reference. Type names are interned:
/// a name the schema does not know is rejected by the caller's type check.
pub fn parse_witness(text: &str) -> Result<TypeRef> {
    let spaced = text.replace('(', " ( ").replace(')', " ) ");
    let tokens: Vec<&str> = spaced.split_whitespace().collect();
    fn read(tokens: &[&str], at: &mut usize) -> Result<TypeRef> {
        let token = *tokens.get(*at).ok_or("malformed type witness")?;
        *at += 1;
        if token != "(" {
            return Ok(TypeRef::Named(intern(token), vec![]));
        }
        let name = *tokens.get(*at).ok_or("malformed type witness")?;
        *at += 1;
        let mut arguments = Vec::new();
        while *tokens.get(*at).ok_or("malformed type witness")? != ")" {
            arguments.push(read(tokens, at)?);
        }
        *at += 1;
        Ok(TypeRef::Named(intern(name), arguments))
    }
    let mut at = 0;
    let result = read(&tokens, &mut at)?;
    if at != tokens.len() {
        return Err("malformed type witness".into());
    }
    Ok(result)
}

/// Witness type names are few; leaking each distinct name once is bounded.
fn intern(name: &str) -> &'static str {
    use std::sync::{Mutex, OnceLock};
    static NAMES: OnceLock<Mutex<std::collections::HashSet<&'static str>>> = OnceLock::new();
    let mut names = NAMES.get_or_init(|| Mutex::new(std::collections::HashSet::new())).lock().unwrap();
    if let Some(found) = names.get(name) {
        return found;
    }
    let leaked: &'static str = Box::leak(name.to_owned().into_boxed_str());
    names.insert(leaked);
    leaked
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

    /// Attach constructors' witnessed existentials (parameter numbers).
    pub fn with_witnesses(mut self, witnesses: &[(&'static str, &'static [usize])]) -> Self {
        self.witnesses.extend(witnesses.iter().copied());
        self
    }

    /// Field types with witnessed existentials read from the trailing witness
    /// fields of a value.
    pub fn witnessed_fields(&self, tag: &str, fields: &[TypeRef], values: &[Value]) -> Result<Vec<TypeRef>> {
        let Some(witnesses) = self.witnesses.get(tag) else {
            return Ok(fields.to_vec());
        };
        if values.len() < witnesses.len() {
            return Err("missing type witness".into());
        }
        let mut keys = Vec::new();
        for value in &values[values.len() - witnesses.len()..] {
            let Value::Text(text) = value else {
                return Err("type witness must be text".into());
            };
            keys.push(text.clone());
        }
        self.fields_at_witnesses(tag, fields, &keys)
    }

    /// Field types at the given witness keys; generated codecs use this too.
    pub fn fields_at_witnesses(&self, tag: &str, fields: &[TypeRef], keys: &[String]) -> Result<Vec<TypeRef>> {
        let witnesses = self.witnesses.get(tag).copied().unwrap_or(&[]);
        let size = witnesses.iter().copied().max().map_or(0, |m| m + 1);
        let mut known: Vec<TypeRef> = (0..size).map(TypeRef::Parameter).collect();
        for (index, key) in witnesses.iter().zip(keys) {
            let ty = parse_witness(key)?;
            self.check_type(&ty, 0)?;
            known[*index] = ty;
        }
        fields.iter().map(|field| substitute_open(field, &known)).collect()
    }

    /// Each choice of witnesses from the pool: the declared fields at it and
    /// the witness values.
    pub fn witness_choices(&self, constructor: &ConstructorSchema) -> Result<Vec<(Vec<TypeRef>, Vec<Value>)>> {
        let Some(witnesses) = self.witnesses.get(constructor.tag) else {
            return Ok(vec![(constructor.fields.clone(), vec![])]);
        };
        let declared = &constructor.fields[..constructor.fields.len() - witnesses.len()];
        let mut choices: Vec<Vec<String>> = vec![vec![]];
        for _ in 0..witnesses.len() {
            choices = choices
                .into_iter()
                .flat_map(|choice| {
                    witness_pool().into_iter().map(move |ty| {
                        let mut next = choice.clone();
                        next.push(witness_key(&ty));
                        next
                    })
                })
                .collect();
        }
        choices
            .into_iter()
            .map(|keys| {
                let fields = self.fields_at_witnesses(constructor.tag, declared, &keys)?;
                Ok((fields, keys.into_iter().map(Value::Text).collect()))
            })
            .collect()
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
            witnesses: HashMap::new(),
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
            // A witnessed existential stays open until a value supplies it.
            extended.push(bound.get(&(parameters + k)).cloned().unwrap_or(TypeRef::Parameter(parameters + k)));
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
        // A native collection arrives as a plain list: retag it, put a Set
        // or KeyVal in canonical order, and a Stack's top first.
        let value = match (collection_tag(name), value) {
            (Some(tag), Value::List(mut items)) => {
                if name.ends_with("::Set") || name.ends_with("::KeyVal") {
                    items = canonical_items(items, name.ends_with("::KeyVal"))?;
                } else if name.ends_with("::Stack") {
                    items.reverse();
                }
                Value::Data(tag.into(), vec![Value::List(items)])
            }
            (_, value) => value,
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
            let instantiated = constructor
                .fields
                .iter()
                .map(|field| field.instantiate(arguments))
                .collect::<Result<Vec<_>>>()?;
            let field_types = self.witnessed_fields(&tag, &instantiated, &fields)?;
            let checked: Vec<Value> = fields
                .into_iter()
                .zip(&field_types)
                .enumerate()
                .map(|(index, (field, field_type))| {
                    self.walk(
                        field,
                        field_type,
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

/// Run an async adapter's future to completion on this thread. A waker that
/// unparks the thread is enough: adapters own whatever executor they need.
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    struct Unpark(std::thread::Thread);
    impl std::task::Wake for Unpark {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }
    let waker = std::task::Waker::from(Arc::new(Unpark(std::thread::current())));
    let mut context = std::task::Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    loop {
        match future.as_mut().poll(&mut context) {
            std::task::Poll::Ready(value) => return value,
            std::task::Poll::Pending => std::thread::park(),
        }
    }
}

/// The portable total order. Exact numbers by value, text by code point,
/// sequences by unit, false before true, absence before presence, lists
/// element by element, Nothing before Just, Left before Right, and other data
/// by constructor identity, then fields left to right.
pub fn compare_values(a: &Value, b: &Value) -> Result<std::cmp::Ordering> {
    use std::cmp::Ordering::*;
    use Value::*;
    fn items(a: &[Value], b: &[Value]) -> Result<std::cmp::Ordering> {
        for (x, y) in a.iter().zip(b) {
            let order = compare_values(x, y)?;
            if order != Equal {
                return Ok(order);
            }
        }
        Ok(a.len().cmp(&b.len()))
    }
    fn optional(a: &Option<Box<Value>>, b: &Option<Box<Value>>) -> Result<std::cmp::Ordering> {
        match (a, b) {
            (None, None) => Ok(Equal),
            (None, Some(_)) => Ok(Less),
            (Some(_), None) => Ok(Greater),
            (Some(x), Some(y)) => compare_values(x, y),
        }
    }
    Ok(match (a, b) {
        (Bool(x), Bool(y)) => x.cmp(y),
        (Integer(_) | Decimal(_) | Rational(_), Integer(_) | Decimal(_) | Rational(_)) => a.exact()?.cmp(&b.exact()?),
        (Text(x), Text(y)) => x.chars().cmp(y.chars()),
        (Char(x), Char(y)) => x.cmp(y),
        (CodePoint(x), CodePoint(y)) => x.cmp(y),
        (CodeUnit16(x), CodeUnit16(y)) => x.cmp(y),
        (CodePointText(x), CodePointText(y)) => x.cmp(y),
        (Utf16Text(x), Utf16Text(y)) => x.cmp(y),
        (Bytes(x), Bytes(y)) => x.cmp(y),
        (Unit, Unit) | (Null, Null) | (Undefined, Undefined) => Equal,
        (Nullable(x), Nullable(y)) | (Optional(x), Optional(y)) | (Maybe(x), Maybe(y)) => optional(x, y)?,
        (Left(_), Right(_)) => Less,
        (Right(_), Left(_)) => Greater,
        (Left(x), Left(y)) | (Right(x), Right(y)) => compare_values(x, y)?,
        (List(x), List(y)) => items(x, y)?,
        (Data(s, x), Data(t, y)) if s == t => items(x, y)?,
        (Data(s, _), Data(t, _)) => s.cmp(t),
        _ => return Err("values have no portable order".into()),
    })
}

/// A Set's items or a KeyVal's entries sorted by key, keeping the last of
/// equal keys.
pub fn canonical_items(items: Vec<Value>, keyed: bool) -> Result<Vec<Value>> {
    let key = |item: &Value| -> Value {
        match (keyed, item) {
            (true, Value::Data(_, fields)) if !fields.is_empty() => fields[0].clone(),
            _ => item.clone(),
        }
    };
    let mut ordered = items;
    let mut failure = None;
    ordered.sort_by(|a, b| match compare_values(&key(a), &key(b)) {
        Ok(order) => order,
        Err(error) => {
            failure = Some(error);
            std::cmp::Ordering::Equal
        }
    });
    if let Some(error) = failure {
        return Err(error);
    }
    let mut result: Vec<Value> = Vec::new();
    for item in ordered {
        if let Some(last) = result.last() {
            if compare_values(&key(last), &key(&item))? == std::cmp::Ordering::Equal {
                *result.last_mut().unwrap() = item;
                continue;
            }
        }
        result.push(item);
    }
    Ok(result)
}

// Workflow runtime. A workflow runs under a runtime: a clock, a seeded
// random source, a trace of what happened, and the state of stateful stages.
// The runtime travels in the Context every generated function takes; without
// one, the default runtime applies (real time). Durations are i64
// microseconds.

/// Tells the time and waits, in microseconds.
pub trait Clock: Send {
    fn now(&self) -> i64;
    fn sleep(&mut self, micros: i64);
}

/// Monotonic wall time.
pub struct RealClock(std::time::Instant);
impl Default for RealClock {
    fn default() -> Self {
        RealClock(std::time::Instant::now())
    }
}
impl Clock for RealClock {
    fn now(&self) -> i64 {
        self.0.elapsed().as_micros() as i64
    }
    fn sleep(&mut self, micros: i64) {
        std::thread::sleep(std::time::Duration::from_micros(micros.max(0) as u64));
    }
}

/// Advances when slept on and returns at once.
#[derive(Default)]
pub struct VirtualClock {
    pub time: i64,
}
impl Clock for VirtualClock {
    fn now(&self) -> i64 {
        self.time
    }
    fn sleep(&mut self, micros: i64) {
        self.time += micros;
    }
}

/// The same sequence on every target for the same seed.
pub struct SplitMix64 {
    state: u64,
}
impl SplitMix64 {
    pub fn new(seed: u64) -> Self {
        SplitMix64 { state: seed }
    }
    pub fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    /// Uniform in [0, bound); 0 when bound is 0.
    pub fn below(&mut self, bound: u64) -> u64 {
        if bound == 0 { 0 } else { self.next() % bound }
    }
}

/// A stage starting or finishing an attempt, or a wait.
#[derive(Clone, Debug, PartialEq)]
pub struct TraceEvent {
    pub kind: &'static str,
    pub stage: String,
    pub number: i64,
    pub succeeded: bool,
}

pub struct WorkflowRuntime {
    pub clock: Box<dyn Clock>,
    pub random: SplitMix64,
    pub trace: Vec<TraceEvent>,
    pub state: HashMap<String, Value>,
    /// Whether rate limits, breakers, bulkheads and caches apply.
    pub gates: bool,
    cache: HashMap<String, Vec<(Value, Value, i64)>>,
    // A frame per running workflow: the undos of its completed stages.
    frames: Vec<Vec<(&'static str, Value, fn(&mut Context, Value) -> Result<Value>)>>,
    // When the running attempt of a stage with a timeout must end.
    deadline: Option<std::time::Instant>,
    // The running attempt's stage and hedge (delay, most).
    hedge: Option<(&'static str, (i64, i64))>,
}
impl std::fmt::Debug for WorkflowRuntime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "WorkflowRuntime {{ trace: {:?} }}", self.trace)
    }
}
impl WorkflowRuntime {
    pub fn new(clock: Box<dyn Clock>, seed: u64) -> Self {
        WorkflowRuntime { clock, random: SplitMix64::new(seed), trace: Vec::new(), state: HashMap::new(), gates: true, cache: HashMap::new(), frames: Vec::new(), deadline: None, hedge: None }
    }
}

static DEFAULT_RUNTIME: std::sync::OnceLock<Arc<std::sync::Mutex<WorkflowRuntime>>> = std::sync::OnceLock::new();

fn workflow_runtime(ctx: &Context) -> Arc<std::sync::Mutex<WorkflowRuntime>> {
    match &ctx.workflow {
        Some(runtime) => runtime.clone(),
        None => DEFAULT_RUNTIME
            .get_or_init(|| Arc::new(std::sync::Mutex::new(WorkflowRuntime::new(Box::new(RealClock::default()), 0))))
            .clone(),
    }
}

/// strategy is immediate, fixed, linear, exponential, fibonacci or custom;
/// delay, step, factor and cap (negative for none) are its parameters.
pub struct Retry {
    pub strategy: &'static str,
    pub delay: i64,
    pub step: i64,
    pub factor: i64,
    pub cap: i64,
    pub attempts: i64,
    pub jitter: &'static str,
    pub when: Option<fn(&mut Context, Value) -> Result<bool>>,
    pub decide: Option<fn(&mut Context, i64, Value, i64) -> Result<Option<i64>>>,
}

/// A stateful policy: start gives its state, admit a Step of the next state
/// and a Gate (Admit, WaitFor or Reject), and finish (when set) the state
/// after the call. wait is -2 to fail at once when not admitted, -1 to wait
/// without bound, or the most it waits.
pub struct Gate {
    pub kind: &'static str,
    pub start: fn(&mut Context, i64) -> Result<Value>,
    pub admit: fn(&mut Context, Value, i64) -> Result<Value>,
    pub finish: Option<fn(&mut Context, Value, i64, bool) -> Result<Value>>,
    pub wait: i64,
}

/// key names the stage's state; cache is how long a success is reused (0
/// or less for none); wraps says failures are StageFailures.
pub struct StagePolicy {
    pub stage: &'static str,
    pub retry: Option<Retry>,
    pub timeout: i64,
    pub key: &'static str,
    pub gates: Vec<Gate>,
    pub cache: i64,
    pub wraps: bool,
    /// Undoes the stage's success value when its workflow fails.
    pub compensate: Option<fn(&mut Context, Value) -> Result<Value>>,
    /// (delay, most): when an attempt has not succeeded after delay, another
    /// starts beside it, up to most in all; the first success wins.
    pub hedge: Option<(i64, i64)>,
}

/// Runs a workflow whose stages compensate: when it fails, the undos of its
/// completed stages run, last first.
pub fn run_workflow(ctx: &mut Context, mut attempt: impl FnMut(&mut Context) -> Result<Value>) -> Result<Value> {
    let runtime = workflow_runtime(ctx);
    runtime.lock().unwrap().frames.push(Vec::new());
    let result = attempt(ctx);
    let frame = runtime.lock().unwrap().frames.pop().unwrap_or_default();
    let result = result?;
    if matches!(result, Value::Left(_)) {
        for (stage, value, undo) in frame.into_iter().rev() {
            runtime.lock().unwrap().trace.push(TraceEvent { kind: "compensate", stage: stage.into(), number: 0, succeeded: true });
            undo(ctx, value)?;
        }
    }
    Ok(result)
}

const STAGE_FAILURE: &str = "lawspec.resilience::type::StageFailure::";
const GATE: &str = "lawspec.resilience::type::Gate::";

fn stage_failure(kind: &str) -> Value {
    Value::Left(Box::new(Value::Data(format!("{STAGE_FAILURE}{kind}"), vec![])))
}

fn gate_key(policy: &StagePolicy, gate: &Gate) -> String {
    format!("{}/{}", if policy.key.is_empty() { policy.stage } else { policy.key }, gate.kind)
}

/// Admits the call (None) or gives the failure to return instead.
fn pass_gate(ctx: &mut Context, runtime: &Arc<std::sync::Mutex<WorkflowRuntime>>, policy: &StagePolicy, gate: &Gate) -> Result<Option<&'static str>> {
    let key = gate_key(policy, gate);
    let failure = match gate.kind { "breaker" => "CircuitOpen", "limit" => "RateLimited", _ => "Saturated" };
    let mut waited = 0i64;
    loop {
        let (now, state) = {
            let guard = runtime.lock().unwrap();
            (guard.clock.now(), guard.state.get(&key).cloned())
        };
        let state = match state { Some(state) => state, None => (gate.start)(ctx, now)? };
        let Value::Data(_, mut step) = (gate.admit)(ctx, state, now)? else { return Err("expected a Step".into()) };
        let decision = step.pop().unwrap();
        runtime.lock().unwrap().state.insert(key.clone(), step.pop().unwrap());
        let Value::Data(tag, fields) = decision else { return Err("expected a Gate".into()) };
        if tag == format!("{GATE}Admit") {
            return Ok(None);
        }
        if tag == format!("{GATE}Reject") || gate.wait == -2 {
            return Ok(Some(failure));
        }
        let delay = match fields.first() {
            Some(Value::Integer(n)) => n.to_i64().ok_or("wait outside i64")?,
            _ => return Err("expected a wait".into()),
        };
        if gate.wait >= 0 && waited + delay > gate.wait {
            return Ok(Some(failure));
        }
        let mut guard = runtime.lock().unwrap();
        guard.trace.push(TraceEvent { kind: "wait", stage: policy.stage.into(), number: delay, succeeded: true });
        guard.clock.sleep(delay);
        waited += delay;
    }
}

fn finish_gate(ctx: &mut Context, runtime: &Arc<std::sync::Mutex<WorkflowRuntime>>, policy: &StagePolicy, gate: &Gate, succeeded: bool) -> Result<()> {
    if let Some(finish) = gate.finish {
        let key = gate_key(policy, gate);
        let (now, state) = {
            let guard = runtime.lock().unwrap();
            (guard.clock.now(), guard.state.get(&key).cloned().ok_or("missing gate state")?)
        };
        let next = finish(ctx, state, now, succeeded)?;
        runtime.lock().unwrap().state.insert(key, next);
    }
    Ok(())
}

fn fibonacci(n: i64) -> i64 {
    let (mut a, mut b) = (1i64, 1i64);
    for _ in 1..n {
        let next = a + b;
        a = b;
        b = next;
    }
    a
}

/// The delay before attempt (2 or more), before jitter.
pub fn retry_delay(retry: &Retry, attempt: i64) -> i64 {
    let n = attempt - 1;
    match retry.strategy {
        "immediate" => 0,
        "fixed" => retry.delay,
        "linear" => retry.delay + retry.step * (n - 1),
        "exponential" => {
            let mut delay = retry.delay;
            for _ in 1..n {
                delay *= retry.factor;
                if retry.cap >= 0 && delay >= retry.cap {
                    return retry.cap;
                }
            }
            if retry.cap >= 0 && delay > retry.cap { retry.cap } else { delay }
        }
        "fibonacci" => retry.delay * fibonacci(n),
        other => panic!("unknown retry strategy: {other}"),
    }
}

/// Full: [0, delay]; equal: delay/2 + [0, delay/2]; decorrelated:
/// [base, previous * 3], capped at delay.
pub fn jittered(jitter: &str, delay: i64, previous: i64, base: i64, random: &mut SplitMix64) -> i64 {
    match jitter {
        "full" => random.below((delay + 1) as u64) as i64,
        "equal" => {
            let half = delay / 2;
            half + random.below((delay - half + 1) as u64) as i64
        }
        "decorrelated" => {
            let high = base.max(previous * 3);
            delay.min(base + random.below((high - base + 1) as u64) as i64)
        }
        _ => delay,
    }
}

/// Runs a stage's attempts under its policy; a Left is a failure. key is the
/// stage's input, for the cache.
pub fn run_stage(
    ctx: &mut Context,
    policy: &StagePolicy,
    attempt: impl FnMut(&mut Context) -> Result<Value>,
    key: Value,
) -> Result<Value> {
    let runtime = workflow_runtime(ctx);
    let gating = runtime.lock().unwrap().gates;
    let cache_key = format!("{}/cache", if policy.key.is_empty() { policy.stage } else { policy.key });
    let caching = policy.cache > 0 && gating;
    if caching {
        let mut guard = runtime.lock().unwrap();
        let now = guard.clock.now();
        let hit = guard.cache.get(&cache_key).and_then(|entries| {
            entries.iter().find(|(entry, _, expires)| now < *expires && equal(entry, &key).unwrap_or(false)).map(|(_, value, _)| value.clone())
        });
        if let Some(value) = hit {
            guard.trace.push(TraceEvent { kind: "cached", stage: policy.stage.into(), number: 0, succeeded: true });
            return Ok(value);
        }
    }
    let gates: &[Gate] = if gating { &policy.gates } else { &[] };
    for (i, gate) in gates.iter().enumerate() {
        if let Some(failure) = pass_gate(ctx, &runtime, policy, gate)? {
            for passed in &gates[..i] {
                finish_gate(ctx, &runtime, policy, passed, false)?;
            }
            return Ok(stage_failure(failure));
        }
    }
    let result = attempts(ctx, &runtime, policy, attempt)?;
    let succeeded = !matches!(result, Value::Left(_));
    for gate in gates {
        finish_gate(ctx, &runtime, policy, gate, succeeded)?;
    }
    if let (Value::Right(value), Some(undo)) = (&result, policy.compensate) {
        if let Some(frame) = runtime.lock().unwrap().frames.last_mut() {
            frame.push((policy.stage, (**value).clone(), undo));
        }
    }
    if caching && succeeded {
        let mut guard = runtime.lock().unwrap();
        let expires = guard.clock.now() + policy.cache;
        let entries = guard.cache.entry(cache_key).or_default();
        entries.retain(|(entry, _, _)| !equal(entry, &key).unwrap_or(false));
        entries.push((key, result.clone(), expires));
    }
    Ok(result)
}

// The error block_on_within gives when an attempt outlives its stage's
// timeout; the stage turns it into TimedOut.
const TIMED_OUT: &str = "\0lawspec: timed out";

/// An async step's logical result: start begins the step and convert turns
/// its native result into a logical value. The step runs within its stage's
/// timeout and hedge, if any, polling its attempts on this thread.
pub fn await_step<F: std::future::Future>(
    ctx: &Context,
    mut start: impl FnMut() -> F,
    convert: impl Fn(F::Output) -> Value,
) -> Result<Value> {
    let runtime = workflow_runtime(ctx);
    let (deadline, hedge) = {
        let guard = runtime.lock().unwrap();
        (guard.deadline, guard.hedge)
    };
    if deadline.is_none() && hedge.is_none() {
        return Ok(convert(block_on(start())));
    }
    let (stage, delay, most) = match hedge {
        Some((stage, (delay, most))) => (stage, std::time::Duration::from_micros(delay as u64), most),
        None => ("", std::time::Duration::ZERO, 1),
    };
    struct Unpark(std::thread::Thread);
    impl std::task::Wake for Unpark {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }
    let waker = std::task::Waker::from(Arc::new(Unpark(std::thread::current())));
    let mut context = std::task::Context::from_waker(&waker);
    let mut pending: Vec<std::pin::Pin<Box<F>>> = Vec::new();
    let (mut started, mut next, mut launch) = (0i64, None, true);
    loop {
        if launch {
            started += 1;
            if started > 1 {
                runtime.lock().unwrap().trace.push(TraceEvent { kind: "hedge", stage: stage.into(), number: started, succeeded: true });
            }
            pending.push(Box::pin(start()));
            next = if started < most { Some(std::time::Instant::now() + delay) } else { None };
            launch = false;
        }
        let mut last = None;
        let mut i = 0;
        while i < pending.len() {
            match pending[i].as_mut().poll(&mut context) {
                std::task::Poll::Ready(output) => {
                    pending.remove(i);
                    let value = convert(output);
                    if !matches!(value, Value::Left(_)) {
                        return Ok(value);
                    }
                    last = Some(value);
                }
                std::task::Poll::Pending => i += 1,
            }
        }
        let now = std::time::Instant::now();
        if deadline.is_some_and(|deadline| now >= deadline) {
            return Err(TIMED_OUT.into());
        }
        if pending.is_empty() {
            if started >= most {
                return Ok(last.expect("the last attempt failed"));
            }
            launch = true;
        } else if next.is_some_and(|next| now >= next) {
            launch = true;
        } else {
            match [deadline, next].into_iter().flatten().min() {
                Some(until) => std::thread::park_timeout(until - now),
                None => std::thread::park(),
            }
        }
    }
}

/// An attempt under its stage's timeout (failing with TimedOut when it
/// outlives it) and hedge. Under the runtime generated tests install (gates
/// off), both are off.
fn scoped(
    ctx: &mut Context,
    runtime: &Arc<std::sync::Mutex<WorkflowRuntime>>,
    policy: &StagePolicy,
    attempt: &mut impl FnMut(&mut Context) -> Result<Value>,
) -> Result<Value> {
    if !runtime.lock().unwrap().gates || (policy.timeout <= 0 && policy.hedge.is_none()) {
        return attempt(ctx);
    }
    let outer = {
        let mut guard = runtime.lock().unwrap();
        let outer = (guard.deadline, guard.hedge);
        if policy.timeout > 0 {
            guard.deadline = Some(std::time::Instant::now() + std::time::Duration::from_micros(policy.timeout as u64));
        }
        guard.hedge = policy.hedge.map(|hedge| (policy.stage, hedge));
        outer
    };
    let result = attempt(ctx);
    {
        let mut guard = runtime.lock().unwrap();
        (guard.deadline, guard.hedge) = outer;
    }
    match result {
        // Callers may have added context to the marker.
        Err(error) if error.contains(TIMED_OUT) => Ok(stage_failure("TimedOut")),
        other => other,
    }
}

fn attempts(
    ctx: &mut Context,
    runtime: &Arc<std::sync::Mutex<WorkflowRuntime>>,
    policy: &StagePolicy,
    mut attempt: impl FnMut(&mut Context) -> Result<Value>,
) -> Result<Value> {
    let event = |kind: &'static str, number: i64, succeeded: bool| TraceEvent { kind, stage: policy.stage.into(), number, succeeded };
    let (mut number, mut previous) = (1i64, 0i64);
    loop {
        runtime.lock().unwrap().trace.push(event("start", number, false));
        let result = scoped(ctx, runtime, policy, &mut attempt)?;
        let failure = match &result {
            Value::Left(error) => Some((**error).clone()),
            _ => None,
        };
        runtime.lock().unwrap().trace.push(event("finish", number, failure.is_none()));
        let (Some(mut failure), Some(retry)) = (failure, &policy.retry) else { return Ok(result) };
        if retry.attempts > 0 && number >= retry.attempts {
            return Ok(result);
        }
        if policy.wraps {
            // Only the step's own failures and timeouts are retried.
            match failure {
                Value::Data(ref tag, ref mut fields) if *tag == format!("{STAGE_FAILURE}StepFailed") && fields.len() == 1 => {
                    failure = fields.pop().unwrap();
                }
                Value::Data(ref tag, _) if *tag == format!("{STAGE_FAILURE}TimedOut") => {}
                _ => return Ok(result),
            }
        }
        if let Some(when) = retry.when {
            if !when(ctx, failure.clone())? {
                return Ok(result);
            }
        }
        number += 1;
        let delay = if retry.strategy == "custom" {
            match (retry.decide.expect("a custom strategy decides"))(ctx, number, failure, previous)? {
                Some(delay) => delay,
                None => return Ok(result),
            }
        } else {
            let base = if retry.strategy == "immediate" { 0 } else { retry_delay(retry, 2) };
            let mut guard = runtime.lock().unwrap();
            jittered(retry.jitter, retry_delay(retry, number), previous, base, &mut guard.random)
        };
        let mut guard = runtime.lock().unwrap();
        guard.trace.push(event("sleep", delay, true));
        guard.clock.sleep(delay);
        previous = delay;
    }
}

/// A logical Duration of whole microseconds.
pub fn duration(micros: i64) -> Value {
    Value::Data(DURATION_TAG.into(), vec![Value::Integer(BigInt::from(micros))])
}

/// A RetryDecision's delay, or None to stop.
pub fn retry_decision(decision: Value) -> Result<Option<i64>> {
    match decision {
        Value::Data(tag, mut fields) if tag == "lawspec.time::type::RetryDecision::RetryAfter" && fields.len() == 1 => {
            match fields.pop().unwrap() {
                Value::Data(_, mut micros) if micros.len() == 1 => match micros.pop().unwrap() {
                    Value::Integer(n) => n.to_i64().map(Some).ok_or_else(|| "delay outside i64".into()),
                    _ => Err("expected Duration microseconds".into()),
                },
                _ => Err("expected a Duration".into()),
            }
        }
        Value::Data(..) => Ok(None),
        _ => Err("expected a RetryDecision".into()),
    }
}

/// A Duration, whole microseconds from 0 to about 146 years, is natively a
/// std::time::Duration. One with a fraction of a microsecond is not a
/// Duration; IntoValue cannot fail, so converting one panics.
pub const DURATION_TAG: &str = "lawspec.time::type::Duration::Duration";

impl IntoValue for std::time::Duration {
    fn into_value(self) -> Value {
        assert!(
            self.subsec_nanos() % 1000 == 0,
            "a Duration is a non-negative whole number of microseconds"
        );
        Value::Data(DURATION_TAG.into(), vec![Value::Integer(BigInt::from(self.as_micros()))])
    }
}
impl FromValue for std::time::Duration {
    fn from_value(value: Value) -> Result<Self> {
        match value {
            Value::Data(tag, fields) if tag == DURATION_TAG && fields.len() == 1 => match &fields[0] {
                Value::Integer(micros) => u64::try_from(micros)
                    .map(std::time::Duration::from_micros)
                    .map_err(|_| "Duration outside the native range".into()),
                _ => Err("expected Duration microseconds".into()),
            },
            _ => Err("expected Duration".into()),
        }
    }
}

/// Built-in collections: natively a BTreeSet, a BTreeMap, a VecDeque (Queue
/// and Deque) or a Vec whose top is last (Stack). Natives convert to plain
/// lists; the schema retags them by the expected type.
pub const COLLECTIONS: &str = "lawspec.collections::type::";

pub fn collection_tag(name: &str) -> Option<&'static str> {
    Some(match name.strip_prefix(COLLECTIONS)? {
        "Set" => "lawspec.collections::type::Set::SetItems",
        "KeyVal" => "lawspec.collections::type::KeyVal::KeyValEntries",
        "Queue" => "lawspec.collections::type::Queue::QueueItems",
        "Stack" => "lawspec.collections::type::Stack::StackItems",
        "Deque" => "lawspec.collections::type::Deque::DequeItems",
        _ => return None,
    })
}

fn collection_items(value: Value) -> Result<Vec<Value>> {
    match value {
        Value::List(items) => Ok(items),
        Value::Data(tag, mut fields) if tag.starts_with(COLLECTIONS) && fields.len() == 1 => {
            let reverse = tag.ends_with("::StackItems");
            match fields.pop().unwrap() {
                Value::List(mut items) => {
                    if reverse {
                        items.reverse();
                    }
                    Ok(items)
                }
                _ => Err("expected collection items".into()),
            }
        }
        _ => Err("expected a collection".into()),
    }
}

impl<T: IntoValue> IntoValue for std::collections::BTreeSet<T> {
    fn into_value(self) -> Value {
        Value::List(self.into_iter().map(IntoValue::into_value).collect())
    }
}
impl<T: FromValue + Ord> FromValue for std::collections::BTreeSet<T> {
    fn from_value(value: Value) -> Result<Self> {
        collection_items(value)?.into_iter().map(T::from_value).collect()
    }
}
impl<K: IntoValue, V: IntoValue> IntoValue for std::collections::BTreeMap<K, V> {
    fn into_value(self) -> Value {
        Value::List(
            self.into_iter()
                .map(|(k, v)| Value::Data("lawspec.collections::type::Entry::Entry".into(), vec![k.into_value(), v.into_value()]))
                .collect(),
        )
    }
}
impl<K: FromValue + Ord, V: FromValue> FromValue for std::collections::BTreeMap<K, V> {
    fn from_value(value: Value) -> Result<Self> {
        collection_items(value)?
            .into_iter()
            .map(|entry| match entry {
                Value::Data(_, fields) if fields.len() == 2 => {
                    let mut fields = fields.into_iter();
                    Ok((K::from_value(fields.next().unwrap())?, V::from_value(fields.next().unwrap())?))
                }
                _ => Err("expected a KeyVal entry".into()),
            })
            .collect()
    }
}
impl<T: IntoValue> IntoValue for std::collections::VecDeque<T> {
    fn into_value(self) -> Value {
        Value::List(self.into_iter().map(IntoValue::into_value).collect())
    }
}
impl<T: FromValue> FromValue for std::collections::VecDeque<T> {
    fn from_value(value: Value) -> Result<Self> {
        collection_items(value)?.into_iter().map(T::from_value).collect()
    }
}

pub fn helper(name: &str, mut args: Vec<Value>) -> Result<Value> {
    use Value::*;
    if name == "select" && args.len() == 3 {
        let other = args.pop().unwrap();
        let chosen = args.pop().unwrap();
        return Ok(if matches!(args[0], Bool(true)) { chosen } else { other });
    }
    if name == "compare" && args.len() == 2 {
        let tag = match compare_values(&args[0], &args[1])? {
            std::cmp::Ordering::Less => "Less",
            std::cmp::Ordering::Equal => "Equal",
            std::cmp::Ordering::Greater => "Greater",
        };
        return Ok(Data(format!("lawspec.collections::type::Ordering::{tag}"), vec![]));
    }
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

// Portable generation for stateful models. A type descriptor is an
// s-expression: (int T lo hi) with _ for no bound, (bool), (text), (unit),
// (list D), (maybe D), (either L R), (data NAME (ctor TAG D...) ...) and
// (ref NAME) for a data type declared in the model's table. Every target
// generates, shrinks and renders the same values for the same seed, so the
// draws, candidate order and rendering below follow the Python reference.

/// A descriptor form. Quoted strings and symbols are one atom: the reference
/// compares them as equal strings.
#[derive(Clone, Debug, PartialEq)]
pub enum Sexp {
    List(Vec<Sexp>),
    Int(BigInt),
    Atom(String),
    Blank,
}

impl Sexp {
    fn items(&self) -> &[Sexp] {
        match self {
            Sexp::List(items) => items,
            other => panic!("expected a descriptor form, got {other:?}"),
        }
    }

    fn kind(&self) -> &str {
        match self.items().first() {
            Some(Sexp::Atom(kind)) => kind,
            _ => "",
        }
    }

    fn name(&self) -> String {
        match self {
            Sexp::Atom(s) => s.clone(),
            Sexp::Int(n) => n.to_string(),
            Sexp::Blank => "None".into(),
            Sexp::List(_) => format!("{self:?}"),
        }
    }

    fn bound(&self) -> Option<BigInt> {
        match self {
            Sexp::Int(n) => Some(n.clone()),
            Sexp::Blank => None,
            other => panic!("expected an integer bound, got {other:?}"),
        }
    }
}

/// Parses s-expressions: lists, integers, strings, symbols and _ (Blank).
pub fn read_descriptor(text: &str) -> Vec<Sexp> {
    let chars: Vec<char> = text.chars().collect();
    let space = |c: char| matches!(c, ' ' | '\t' | '\r' | '\n');
    fn skip(chars: &[char], at: &mut usize, space: &dyn Fn(char) -> bool) {
        while *at < chars.len() && space(chars[*at]) {
            *at += 1;
        }
    }
    fn item(chars: &[char], at: &mut usize, space: &dyn Fn(char) -> bool) -> Sexp {
        skip(chars, at, space);
        match chars[*at] {
            '(' => {
                *at += 1;
                let mut items = Vec::new();
                skip(chars, at, space);
                while chars[*at] != ')' {
                    items.push(item(chars, at, space));
                    skip(chars, at, space);
                }
                *at += 1;
                Sexp::List(items)
            }
            '"' => {
                *at += 1;
                let mut out = String::new();
                while chars[*at] != '"' {
                    if chars[*at] == '\\' {
                        *at += 1;
                    }
                    out.push(chars[*at]);
                    *at += 1;
                }
                *at += 1;
                Sexp::Atom(out)
            }
            _ => {
                let start = *at;
                while *at < chars.len() && !space(chars[*at]) && chars[*at] != '(' && chars[*at] != ')' {
                    *at += 1;
                }
                let atom: String = chars[start..*at].iter().collect();
                let digits = atom.trim_start_matches('-');
                if atom == "_" {
                    Sexp::Blank
                } else if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
                    atom.parse::<BigInt>().map(Sexp::Int).unwrap_or(Sexp::Atom(atom))
                } else {
                    Sexp::Atom(atom)
                }
            }
        }
    }
    let mut at = 0;
    let mut forms = Vec::new();
    skip(&chars, &mut at, &space);
    while at < chars.len() {
        forms.push(item(&chars, &mut at, &space));
        skip(&chars, &mut at, &space);
    }
    forms
}

const UNBOUNDED: i64 = 1_000_000;

// Uniform in [0, bound) like SplitMix64::below, but for any bound: a range
// such as UInt64's is 2^64 wide.
fn below_big(random: &mut SplitMix64, bound: &BigInt) -> BigInt {
    if bound.is_positive() { BigInt::from(random.next()) % bound } else { BigInt::zero() }
}

fn below_len(random: &mut SplitMix64, bound: i64) -> usize {
    if bound > 0 { random.below(bound as u64) as usize } else { 0 }
}

/// Generation, shrinking and rendering over a table of data types.
#[derive(Clone, Debug)]
pub struct Values {
    pub table: HashMap<String, Sexp>,
}

impl Values {
    pub fn new(table: HashMap<String, Sexp>) -> Self {
        Values { table }
    }

    pub fn resolve<'a>(&'a self, d: &'a Sexp) -> &'a Sexp {
        if d.kind() == "ref" {
            let name = d.items()[1].name();
            self.table.get(&name).unwrap_or_else(|| panic!("unknown data type {name}"))
        } else {
            d
        }
    }

    /// An integer's range: a missing bound is 1,000,000 from zero, or
    /// 2,000,000 from the other bound when that is beyond it.
    pub fn bounds(&self, d: &Sexp) -> (BigInt, BigInt) {
        let items = d.items();
        let far = BigInt::from(UNBOUNDED);
        match (items[2].bound(), items[3].bound()) {
            (None, None) => (-far.clone(), far),
            (None, Some(hi)) => ((-far.clone()).min(&hi - 2 * &far), hi),
            (Some(lo), None) => (lo.clone(), far.clone().max(&lo + 2 * &far)),
            (Some(lo), Some(hi)) => (lo, hi),
        }
    }

    /// The constructors whose fields mention no data type.
    pub fn base<'a>(&self, d: &'a Sexp) -> Vec<&'a Sexp> {
        let ctors = &d.items()[2..];
        let found: Vec<&Sexp> = ctors.iter().filter(|c| !c.items()[2..].iter().any(mentions_data)).collect();
        if found.is_empty() { ctors.iter().collect() } else { found }
    }

    pub fn generate(&self, d: &Sexp, random: &mut SplitMix64, size: i64) -> Value {
        let d = self.resolve(d);
        let items = d.items();
        match d.kind() {
            "int" => {
                let (lo, hi) = self.bounds(d);
                if random.below(10) < 2 {
                    let specials = [lo.clone(), hi.clone(), clamp(0, &lo, &hi), clamp(1, &lo, &hi)];
                    return Value::Integer(specials[random.below(4) as usize].clone());
                }
                let offset = below_big(random, &(&hi - &lo + 1));
                Value::Integer(lo + offset)
            }
            "bool" => Value::Bool(random.below(2) == 1),
            "text" => {
                let n = below_len(random, size + 1);
                Value::Text((0..n).map(|_| char::from(32 + random.below(95) as u8)).collect())
            }
            "unit" => Value::Unit,
            "list" => {
                let n = below_len(random, size + 1);
                Value::List((0..n).map(|_| self.generate(&items[1], random, size)).collect())
            }
            "maybe" => {
                if random.below(4) == 0 {
                    return Value::Maybe(None);
                }
                Value::Maybe(Some(Box::new(self.generate(&items[1], random, size))))
            }
            "either" => {
                if random.below(2) == 0 {
                    return Value::Left(Box::new(self.generate(&items[1], random, size)));
                }
                Value::Right(Box::new(self.generate(&items[2], random, size)))
            }
            "data" => {
                let choices: Vec<&Sexp> = if size <= 0 { self.base(d) } else { items[2..].iter().collect() };
                let ctor = choices[random.below(choices.len() as u64) as usize].items();
                let fields = ctor[2..].iter().map(|f| self.generate(f, random, (size - 1).max(0))).collect();
                Value::Data(ctor[1].name(), fields)
            }
            _ => panic!("unknown descriptor {d:?}"),
        }
    }

    pub fn minimal(&self, d: &Sexp) -> Value {
        let d = self.resolve(d);
        let items = d.items();
        match d.kind() {
            "int" => {
                let (lo, hi) = self.bounds(d);
                Value::Integer(clamp(0, &lo, &hi))
            }
            "bool" => Value::Bool(false),
            "text" => Value::Text(String::new()),
            "unit" => Value::Unit,
            "list" => Value::List(Vec::new()),
            "maybe" => Value::Maybe(None),
            "either" => Value::Left(Box::new(self.minimal(&items[1]))),
            _ => {
                let ctor = self.base(d)[0].items();
                Value::Data(ctor[1].name(), ctor[2..].iter().map(|f| self.minimal(f)).collect())
            }
        }
    }

    /// Smaller candidates for v, most aggressive first.
    pub fn shrink(&self, d: &Sexp, v: &Value) -> Vec<Value> {
        let d = self.resolve(d);
        let items = d.items();
        let mut out: Vec<Value> = Vec::new();
        match (d.kind(), v) {
            ("int", Value::Integer(n)) => {
                let target = match self.minimal(d) {
                    Value::Integer(t) => t,
                    _ => unreachable!(),
                };
                if *n != target {
                    let step = if *n > target { BigInt::one() } else { -BigInt::one() };
                    out = vec![
                        Value::Integer(target.clone()),
                        Value::Integer(n - toward_zero(&(n - &target), 2)),
                        Value::Integer(n - step),
                    ];
                }
            }
            ("bool", Value::Bool(b)) => {
                if *b {
                    out = vec![Value::Bool(false)];
                }
            }
            ("text", Value::Text(s)) => {
                let cs: Vec<char> = s.chars().collect();
                if !cs.is_empty() {
                    out.push(Value::Text(String::new()));
                    out.push(Value::Text(cs[..cs.len() / 2].iter().collect()));
                    for i in 0..cs.len() {
                        out.push(Value::Text(cs[..i].iter().chain(&cs[i + 1..]).collect()));
                    }
                }
            }
            ("list", Value::List(xs)) => {
                if !xs.is_empty() {
                    out.push(Value::List(Vec::new()));
                    out.push(Value::List(xs[..xs.len() / 2].to_vec()));
                    for i in 0..xs.len() {
                        out.push(Value::List(xs[..i].iter().chain(&xs[i + 1..]).cloned().collect()));
                    }
                    for (i, x) in xs.iter().enumerate() {
                        for c in self.shrink(&items[1], x) {
                            let mut ys = xs.clone();
                            ys[i] = c;
                            out.push(Value::List(ys));
                        }
                    }
                }
            }
            ("maybe", Value::Maybe(Some(x))) => {
                out.push(Value::Maybe(None));
                out.extend(self.shrink(&items[1], x).into_iter().map(|c| Value::Maybe(Some(Box::new(c)))));
            }
            ("either", Value::Left(x)) => {
                out = self.shrink(&items[1], x).into_iter().map(|c| Value::Left(Box::new(c))).collect();
            }
            ("either", Value::Right(x)) => {
                out = self.shrink(&items[2], x).into_iter().map(|c| Value::Right(Box::new(c))).collect();
            }
            ("data", Value::Data(tag, fields)) => {
                let ctor = items[2..]
                    .iter()
                    .find(|c| c.items()[1].name() == *tag)
                    .unwrap_or_else(|| panic!("no constructor {tag}"))
                    .items();
                let own = Sexp::List(vec![Sexp::Atom("ref".into()), items[1].clone()]);
                out.push(self.minimal(d));
                // A field of the same type is a smaller value of it.
                out.extend(fields.iter().zip(&ctor[2..]).filter(|(_, fd)| **fd == own).map(|(f, _)| f.clone()));
                for (i, (field, fd)) in fields.iter().zip(&ctor[2..]).enumerate() {
                    for c in self.shrink(fd, field) {
                        let mut fs = fields.clone();
                        fs[i] = c;
                        out.push(Value::Data(tag.clone(), fs));
                    }
                }
            }
            _ => {}
        }
        let own = render(v);
        let mut seen: Vec<String> = Vec::new();
        let mut unique = Vec::new();
        for c in out {
            let text = render(&c);
            if text != own && !seen.contains(&text) {
                seen.push(text);
                unique.push(c);
            }
        }
        unique
    }
}

fn clamp(n: i64, lo: &BigInt, hi: &BigInt) -> BigInt {
    BigInt::from(n).max(lo.clone()).min(hi.clone())
}

fn toward_zero(n: &BigInt, d: i64) -> BigInt {
    let q = n.abs() / d;
    if n.is_negative() { -q } else { q }
}

fn mentions_data(d: &Sexp) -> bool {
    match d {
        Sexp::List(items) => {
            matches!(items.first(), Some(Sexp::Atom(k)) if k == "ref" || k == "data")
                || items.iter().skip(1).any(mentions_data)
        }
        _ => false,
    }
}

/// A value's canonical text, the same on every target.
pub fn render(v: &Value) -> String {
    let all = |xs: &[Value]| xs.iter().map(render).collect::<Vec<_>>().join(", ");
    match v {
        Value::Bool(b) => (if *b { "true" } else { "false" }).into(),
        Value::Integer(n) => n.to_string(),
        Value::Text(s) => format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"")),
        Value::Unit => "()".into(),
        Value::List(xs) => format!("[{}]", all(xs)),
        Value::Maybe(None) => "Nothing".into(),
        Value::Maybe(Some(x)) => format!("Just({})", render(x)),
        Value::Left(x) => format!("Left({})", render(x)),
        Value::Right(x) => format!("Right({})", render(x)),
        Value::Data(tag, fields) => {
            let name = tag.rsplit("::").next().unwrap_or(tag);
            if fields.is_empty() { name.into() } else { format!("{name}({})", all(fields)) }
        }
        other => format!("{other:?}"),
    }
}

/// A descriptor text's data types and its last form, the one generated.
pub fn values_from(text: &str) -> (Values, Sexp) {
    let mut forms = read_descriptor(text);
    let table = forms
        .iter()
        .filter(|f| matches!(f, Sexp::List(_)) && f.kind() == "data")
        .map(|f| (f.items()[1].name(), f.clone()))
        .collect();
    let last = forms.pop().expect("a descriptor");
    (Values::new(table), last)
}

/// count values generated from one SplitMix64 seed, rendered.
pub fn generated(text: &str, seed: u64, size: i64, count: i64) -> Vec<String> {
    let (values, d) = values_from(text);
    let mut random = SplitMix64::new(seed);
    (0..count).map(|_| render(&values.generate(&d, &mut random, size))).collect()
}

/// The shrink candidates of the first value generated, rendered.
pub fn shrunk(text: &str, seed: u64, size: i64) -> Vec<String> {
    let (values, d) = values_from(text);
    let first = values.generate(&d, &mut SplitMix64::new(seed), size);
    values.shrink(&d, &first).iter().map(render).collect()
}

// Stateful models. A model's spec (see LawSpec.MachineSpec) lists its data
// types, start and commands; the callbacks beside it are the generated
// definitions that call the adapters, the references over the model state,
// preconditions, the abstraction and invariants. A run is generated by
// simulating the pure model, so every command in it is allowed by typestate,
// its precondition and its reference; it is then executed against the
// adapters and every result, abstracted state and invariant is checked. A
// failing run is shrunk by dropping commands and shrinking arguments,
// replaying the model to keep each candidate valid. The draws, candidate
// order and messages follow the Python reference.

/// A generated definition: the context, then its arguments.
pub type ModelCallback = fn(&mut Context, Vec<Value>) -> Result<Value>;

/// A stateful model: its spec and the callbacks in the order the spec lists
/// them. start is [run, model]; each command is (run, reference, when).
pub struct Model {
    pub spec: &'static str,
    pub start: [ModelCallback; 2],
    pub commands: Vec<(ModelCallback, ModelCallback, Option<ModelCallback>)>,
    pub abstract_state: Option<ModelCallback>,
    pub invariants: Vec<ModelCallback>,
}

enum ModelNeed {
    AtLeast(i64),
    Exactly(i64),
}

enum ModelShift {
    By(i64),
    To(i64),
}

struct ModelCommand {
    name: String,
    arguments: Vec<Sexp>,
    state: usize,
    unit: bool,
    needs: Vec<ModelNeed>,
    shifts: Vec<ModelShift>,
    run: ModelCallback,
    reference: ModelCallback,
    when: Option<ModelCallback>,
}

fn sexp_i64(s: &Sexp) -> i64 {
    match s {
        Sexp::Int(n) => n.to_i64().unwrap_or_else(|| panic!("index {n} out of range")),
        other => panic!("expected an integer, got {other:?}"),
    }
}

// The fields of a form, by their first atom.
fn form_fields(items: &[Sexp]) -> HashMap<String, Vec<Sexp>> {
    items.iter().map(|f| (f.kind().to_string(), f.items()[1..].to_vec())).collect()
}

impl ModelCommand {
    fn new(form: &Sexp, callbacks: &(ModelCallback, ModelCallback, Option<ModelCallback>)) -> Self {
        let items = form.items();
        let fields = form_fields(&items[2..]);
        let field = |name: &str| fields.get(name).unwrap_or_else(|| panic!("command without {name}")).clone();
        let pair = |f: &Sexp| (f.kind().to_string(), sexp_i64(&f.items()[1]));
        ModelCommand {
            name: items[1].name(),
            arguments: field("arguments"),
            state: sexp_i64(&field("state")[0]) as usize,
            unit: field("unit")[0].name() == "true",
            needs: field("needs")
                .iter()
                .map(|n| match pair(n) {
                    (k, i) if k == "atleast" => ModelNeed::AtLeast(i),
                    (_, i) => ModelNeed::Exactly(i),
                })
                .collect(),
            shifts: field("shifts")
                .iter()
                .map(|s| match pair(s) {
                    (k, d) if k == "by" => ModelShift::By(d),
                    (_, k) => ModelShift::To(k),
                })
                .collect(),
            run: callbacks.0,
            reference: callbacks.1,
            when: callbacks.2,
        }
    }

    fn admits(&self, indices: &[i64]) -> bool {
        self.needs.iter().zip(indices).all(|(n, i)| match n {
            ModelNeed::AtLeast(k) => i >= k,
            ModelNeed::Exactly(k) => i == k,
        })
    }

    fn shifted(&self, indices: &[i64]) -> Vec<i64> {
        self.shifts
            .iter()
            .zip(indices)
            .map(|(s, i)| match s {
                ModelShift::By(d) => i + d,
                ModelShift::To(k) => *k,
            })
            .collect()
    }
}

// Why a model step did not go through: the model does not allow it, or a
// callback failed.
enum ModelFault {
    Invalid,
    Error(String),
}

// A run: the start's arguments, then each command's index and arguments.
type ModelRun = (Vec<Value>, Vec<(usize, Vec<Value>)>);

struct Machine<'a> {
    model: &'a Model,
    name: String,
    shared: bool,
    values: Values,
    start_indices: Vec<i64>,
    start_arguments: Vec<Sexp>,
    commands: Vec<ModelCommand>,
    invariants: Vec<(String, ModelCallback)>,
}

impl<'a> Machine<'a> {
    fn new(model: &'a Model) -> Self {
        let forms = read_descriptor(model.spec);
        let head = forms[0].items();
        let table = forms
            .iter()
            .filter(|f| f.kind() == "data")
            .map(|f| (f.items()[1].name(), f.clone()))
            .collect();
        let start = forms.iter().find(|f| f.kind() == "start").expect("a model start");
        let start_fields = form_fields(&start.items()[1..]);
        let kinds = forms.iter().find(|f| f.kind() == "invariants").expect("model invariants").items()[1..].to_vec();
        Machine {
            model,
            name: head[1].name(),
            shared: head[2].name() == "shared",
            values: Values::new(table),
            start_indices: start_fields.get("indices").map(|is| is.iter().map(sexp_i64).collect()).unwrap_or_default(),
            start_arguments: start_fields.get("arguments").cloned().unwrap_or_default(),
            commands: forms
                .iter()
                .filter(|f| f.kind() == "command")
                .zip(&model.commands)
                .map(|(f, c)| ModelCommand::new(f, c))
                .collect(),
            invariants: kinds.iter().map(Sexp::name).zip(model.invariants.iter().copied()).collect(),
        }
    }

    /// Whether the model allows every step of a run.
    fn simulate(&self, run: &ModelRun) -> bool {
        let mut ctx = Context::testing();
        let Ok(mut state) = (self.model.start[1])(&mut ctx, run.0.clone()) else {
            return false;
        };
        let mut indices = self.start_indices.clone();
        for (index, args) in &run.1 {
            let command = &self.commands[*index];
            if !command.admits(&indices) {
                return false;
            }
            match step_model(command, &mut ctx, args, state) {
                Ok((next, _)) => state = next,
                Err(ModelFault::Invalid) => return false,
                Err(ModelFault::Error(e)) => panic!("model {}: {e}", self.name),
            }
            indices = command.shifted(&indices);
        }
        true
    }

    fn generate_run(&self, random: &mut SplitMix64, length: u64, size: i64) -> ModelRun {
        let mut ctx = Context::testing();
        let start_args: Vec<Value> = self.start_arguments.iter().map(|d| self.values.generate(d, random, size)).collect();
        let Ok(mut state) = (self.model.start[1])(&mut ctx, start_args.clone()) else {
            return (start_args, Vec::new());
        };
        let mut indices = self.start_indices.clone();
        let mut steps = Vec::new();
        for _ in 0..length {
            let allowed: Vec<usize> = (0..self.commands.len()).filter(|&i| self.commands[i].admits(&indices)).collect();
            if allowed.is_empty() {
                break;
            }
            let index = allowed[random.below(allowed.len() as u64) as usize];
            let command = &self.commands[index];
            let args: Vec<Value> = command.arguments.iter().map(|d| self.values.generate(d, random, size)).collect();
            match step_model(command, &mut ctx, &args, state.clone()) {
                Ok((next, _)) => state = next,
                Err(ModelFault::Invalid) => continue,
                Err(ModelFault::Error(e)) => panic!("model {}: {e}", self.name),
            }
            steps.push((index, args));
            indices = command.shifted(&indices);
        }
        (start_args, steps)
    }

    /// None when the system agrees with the model along the run; otherwise
    /// the failing step's number and what went wrong.
    fn execute(&self, run: &ModelRun) -> Option<(usize, String)> {
        let mut step = 0;
        match self.execute_steps(run, &mut step) {
            Ok(None) => None,
            Ok(Some(message)) => Some((step, message)),
            Err(ModelFault::Invalid) => Some((step, "the model does not allow this step".into())),
            Err(ModelFault::Error(e)) => Some((step, format!("raised error: {e}"))),
        }
    }

    fn execute_steps(&self, run: &ModelRun, step: &mut usize) -> std::result::Result<Option<String>, ModelFault> {
        let mut ctx = Context::testing();
        let mut state = (self.model.start[0])(&mut ctx, run.0.clone()).map_err(ModelFault::Error)?;
        let mut expected = (self.model.start[1])(&mut ctx, run.0.clone()).map_err(ModelFault::Error)?;
        if let Some(failure) = self.check_state(&mut ctx, &state, &expected)? {
            return Ok(Some(failure));
        }
        for (index, args) in &run.1 {
            *step += 1;
            let command = &self.commands[*index];
            let mut full = args.clone();
            full.insert(command.state, state.clone());
            let out = (command.run)(&mut ctx, full).map_err(ModelFault::Error)?;
            let result = if self.shared {
                out
            } else {
                let Value::Data(_, mut fields) = out else {
                    return Err(ModelFault::Error(format!("command {} did not return its state", command.name)));
                };
                let Some(last) = fields.pop() else {
                    return Err(ModelFault::Error(format!("command {} did not return its state", command.name)));
                };
                let result = if command.unit { Value::Unit } else { fields.into_iter().next().unwrap_or(last.clone()) };
                state = last;
                result
            };
            let (next, wanted) = step_model(command, &mut ctx, args, expected)?;
            expected = next;
            if !command.unit
                && compare_values(&result, &wanted).map_err(ModelFault::Error)? != std::cmp::Ordering::Equal
            {
                return Ok(Some(format!("returned {}; the model returns {}", render(&result), render(&wanted))));
            }
            if let Some(failure) = self.check_state(&mut ctx, &state, &expected)? {
                return Ok(Some(failure));
            }
        }
        Ok(None)
    }

    fn check_state(
        &self,
        ctx: &mut Context,
        state: &Value,
        expected: &Value,
    ) -> std::result::Result<Option<String>, ModelFault> {
        if let Some(abstraction) = self.model.abstract_state {
            let actual = abstraction(ctx, vec![state.clone()]).map_err(ModelFault::Error)?;
            if compare_values(&actual, expected).map_err(ModelFault::Error)? != std::cmp::Ordering::Equal {
                return Ok(Some(format!("the state is {}; the model is {}", render(&actual), render(expected))));
            }
        }
        for (kind, invariant) in &self.invariants {
            let subject = if kind == "model" { expected } else { state };
            let holds = invariant(ctx, vec![subject.clone()]).and_then(|v| v.boolean()).map_err(ModelFault::Error)?;
            if !holds {
                return Ok(Some(format!("an invariant on the {kind} fails")));
            }
        }
        Ok(None)
    }

    fn shrink_candidates(&self, run: &ModelRun) -> Vec<ModelRun> {
        let (start_args, steps) = run;
        let mut out = Vec::new();
        let n = steps.len();
        let mut size = n / 2;
        while size >= 1 {
            for begin in (0..n).step_by(size) {
                let kept = steps[..begin].iter().chain(steps.get(begin + size..).unwrap_or(&[])).cloned().collect();
                out.push((start_args.clone(), kept));
            }
            size /= 2;
        }
        for (k, (index, args)) in steps.iter().enumerate() {
            let command = &self.commands[*index];
            for (j, (d, arg)) in command.arguments.iter().zip(args).enumerate() {
                for c in self.values.shrink(d, arg) {
                    let mut changed = steps.clone();
                    changed[k].1[j] = c;
                    out.push((start_args.clone(), changed));
                }
            }
        }
        for (j, (d, arg)) in self.start_arguments.iter().zip(start_args).enumerate() {
            for c in self.values.shrink(d, arg) {
                let mut changed = start_args.clone();
                changed[j] = c;
                out.push((changed, steps.clone()));
            }
        }
        out
    }

    fn shrink_run(&self, mut run: ModelRun, mut failure: (usize, String), max_shrinks: i64) -> (ModelRun, (usize, String)) {
        let mut budget = max_shrinks;
        'shrinking: while budget > 0 {
            let mut improved = false;
            for candidate in self.shrink_candidates(&run) {
                budget -= 1;
                if budget <= 0 {
                    break 'shrinking;
                }
                if !self.simulate(&candidate) {
                    continue;
                }
                if let Some(found) = self.execute(&candidate) {
                    run = candidate;
                    failure = found;
                    improved = true;
                    break;
                }
            }
            if !improved {
                break;
            }
        }
        (run, failure)
    }

    fn describe_run(&self, run: &ModelRun) -> String {
        let all = |xs: &[Value]| xs.iter().map(render).collect::<Vec<_>>().join(", ");
        let mut parts = vec![format!("start({})", all(&run.0))];
        parts.extend(run.1.iter().map(|(i, args)| format!("{}({})", self.commands[*i].name, all(args))));
        parts.join("; ")
    }
}

// A reference step over the model state: the next state and the result.
fn step_model(
    command: &ModelCommand,
    ctx: &mut Context,
    args: &[Value],
    state: Value,
) -> std::result::Result<(Value, Value), ModelFault> {
    if let Some(when) = command.when {
        match when(ctx, vec![state.clone()]).and_then(|v| v.boolean()) {
            Ok(true) => {}
            _ => return Err(ModelFault::Invalid),
        }
    }
    let mut full = args.to_vec();
    full.push(state);
    let out = (command.reference)(ctx, full).map_err(|_| ModelFault::Invalid)?;
    if command.unit {
        return Ok((out, Value::Unit));
    }
    match out {
        Value::Data(_, fields) if fields.len() >= 2 => {
            let mut fields = fields.into_iter();
            let result = fields.next().unwrap();
            Ok((fields.next().unwrap(), result))
        }
        other => Err(ModelFault::Error(format!(
            "the reference for {} returned {}, not a pair",
            command.name,
            render(&other)
        ))),
    }
}

/// Checks the system against its model on generated runs (100 cases of up
/// to 20 commands, seeded by LAWSPEC_SEED); a failure names the shortest
/// failing run found.
pub fn check_model(model: &Model) -> std::result::Result<(), String> {
    let (cases, max_length, max_shrinks) = (100u64, 20u64, 2000i64);
    let seed = std::env::var("LAWSPEC_SEED").ok().and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0);
    let machine = Machine::new(model);
    let mut random = SplitMix64::new(seed);
    for case in 0..cases {
        let length = random.below(max_length + 1);
        let run = machine.generate_run(&mut random, length, 1 + (case % 8) as i64);
        if let Some(failure) = machine.execute(&run) {
            let (run, (step, message)) = machine.shrink_run(run, failure, max_shrinks);
            return Err(format!(
                "model {} fails at step {} of {}: {}",
                machine.name,
                step,
                machine.describe_run(&run),
                message
            ));
        }
    }
    Ok(())
}

// Parallel runs of a shared model. A case is a sequential prefix and one
// branch per thread, generated so that the model allows every interleaving
// of the branches (a search over each thread's position and the model
// state, memoized). The system runs the branches at the same time, each
// call's start and return recorded on one counter, with random yields and
// short sleeps around calls to shake out rare schedules. The history must
// be linearizable: some interleaving that keeps every call after those that
// returned before it started must give every result the model gives and
// leave the state it leaves (a Wing-Gong search, memoized on the same
// positions and model state). Each case runs several times. The draws,
// candidate order and messages follow the Python reference.

const PARALLEL_THREADS: usize = 3;
const PARALLEL_BRANCH: u64 = 5;

// A branch: each command's index and arguments.
type ModelBranch = Vec<(usize, Vec<Value>)>;
type ParallelCase = (ModelRun, Vec<ModelBranch>);
// One call of a branch: when it started, when it returned, and its result.
type ParallelCall = (u64, u64, Value);

fn branch_name(i: usize) -> char {
    (b'A' + i as u8) as char
}

// Positions with thread i's moved one step on.
fn advanced(positions: &[usize], i: usize) -> Vec<usize> {
    let mut next = positions.to_vec();
    next[i] += 1;
    next
}

/// Nothing, a yield, or a sleep of 10 or 100 microseconds.
fn perturb(random: &mut SplitMix64) {
    match random.below(4) {
        0 => {}
        1 => std::thread::yield_now(),
        2 => std::thread::sleep(std::time::Duration::from_micros(10)),
        _ => std::thread::sleep(std::time::Duration::from_micros(100)),
    }
}

impl<'a> Machine<'a> {
    /// The model state after a run, or None when the model does not allow it.
    fn simulate_state(&self, ctx: &mut Context, run: &ModelRun) -> Option<Value> {
        let mut state = (self.model.start[1])(ctx, run.0.clone()).ok()?;
        let mut indices = self.start_indices.clone();
        for (index, args) in &run.1 {
            let command = &self.commands[*index];
            if !command.admits(&indices) {
                return None;
            }
            match step_model(command, ctx, args, state) {
                Ok((next, _)) => state = next,
                Err(ModelFault::Invalid) => return None,
                Err(ModelFault::Error(e)) => panic!("model {}: {e}", self.name),
            }
            indices = command.shifted(&indices);
        }
        Some(state)
    }

    /// Whether the model allows the prefix then every interleaving.
    fn parallel_allowed(&self, prefix: &ModelRun, branches: &[ModelBranch]) -> bool {
        let mut ctx = Context::testing();
        let Some(start) = self.simulate_state(&mut ctx, prefix) else {
            return false;
        };
        let mut seen = std::collections::HashSet::new();
        self.allowed_from(&mut ctx, branches, &mut seen, vec![0; branches.len()], start)
    }

    fn allowed_from(
        &self,
        ctx: &mut Context,
        branches: &[ModelBranch],
        seen: &mut std::collections::HashSet<(Vec<usize>, String)>,
        positions: Vec<usize>,
        state: Value,
    ) -> bool {
        if !seen.insert((positions.clone(), render(&state))) {
            return true;
        }
        for (i, branch) in branches.iter().enumerate() {
            let k = positions[i];
            if k < branch.len() {
                let (index, args) = &branch[k];
                let after = match step_model(&self.commands[*index], ctx, args, state.clone()) {
                    Ok((next, _)) => next,
                    Err(ModelFault::Invalid) => return false,
                    Err(ModelFault::Error(e)) => panic!("model {}: {e}", self.name),
                };
                if !self.allowed_from(ctx, branches, seen, advanced(&positions, i), after) {
                    return false;
                }
            }
        }
        true
    }

    fn generate_branch(&self, random: &mut SplitMix64, mut state: Value, length: u64, size: i64) -> ModelBranch {
        let mut ctx = Context::testing();
        let mut steps = Vec::new();
        for _ in 0..length {
            let index = random.below(self.commands.len() as u64) as usize;
            let command = &self.commands[index];
            let args: Vec<Value> = command.arguments.iter().map(|d| self.values.generate(d, random, size)).collect();
            match step_model(command, &mut ctx, &args, state.clone()) {
                Ok((next, _)) => state = next,
                Err(ModelFault::Invalid) => continue,
                Err(ModelFault::Error(e)) => panic!("model {}: {e}", self.name),
            }
            steps.push((index, args));
        }
        steps
    }

    fn generate_parallel(&self, random: &mut SplitMix64, size: i64, threads: usize, branch_length: u64) -> ParallelCase {
        let length = random.below(4);
        let prefix = self.generate_run(random, length, size);
        let Some(state) = self.simulate_state(&mut Context::testing(), &prefix) else {
            return (prefix, vec![Vec::new(); threads]);
        };
        let mut branches = Vec::new();
        for _ in 0..threads {
            let length = 1 + random.below(branch_length);
            branches.push(self.generate_branch(random, state.clone(), length, size));
        }
        // Drop the last step of the longest branch (the first, among equals)
        // until every interleaving is allowed.
        while !self.parallel_allowed(&prefix, &branches) {
            let mut longest = 0;
            for i in 1..threads {
                if branches[i].len() > branches[longest].len() {
                    longest = i;
                }
            }
            branches[longest].pop();
        }
        (prefix, branches)
    }

    /// None when the history is linearizable; otherwise what went wrong.
    fn execute_parallel(&self, case: &ParallelCase, shake: u64) -> Option<String> {
        let (prefix, branches) = case;
        let mut ctx = Context::testing();
        let state = match self.run_prefix(&mut ctx, prefix) {
            Ok(state) => state,
            Err(e) => return Some(format!("the prefix raised error: {e}")),
        };
        // What each thread needs: the call, the command's name and the full
        // arguments, all Send.
        let calls: Vec<Vec<(ModelCallback, String, Vec<Value>)>> = branches
            .iter()
            .map(|branch| {
                branch
                    .iter()
                    .map(|(index, args)| {
                        let command = &self.commands[*index];
                        let mut full = args.clone();
                        full.insert(command.state, state.clone());
                        (command.run, command.name.clone(), full)
                    })
                    .collect()
            })
            .collect();
        let clock = std::sync::atomic::AtomicU64::new(0);
        let errors = std::sync::Mutex::new(Vec::<String>::new());
        let tick = || clock.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let history: Vec<Vec<ParallelCall>> = std::thread::scope(|scope| {
            let handles: Vec<_> = calls
                .into_iter()
                .enumerate()
                .map(|(i, branch)| {
                    let (tick, errors) = (&tick, &errors);
                    scope.spawn(move || {
                        let mut own = Context::testing();
                        let mut random = SplitMix64::new(shake ^ ((i as u64 + 1).wrapping_mul(0x9E3779B97F4A7C15)));
                        let mut out = Vec::new();
                        for (run, name, full) in branch {
                            perturb(&mut random);
                            let called = tick();
                            let result = match run(&mut own, full) {
                                Ok(result) => result,
                                Err(e) => {
                                    errors.lock().unwrap_or_else(|p| p.into_inner()).push(format!("{name} raised error: {e}"));
                                    Value::Unit
                                }
                            };
                            out.push((called, tick(), result));
                            perturb(&mut random);
                        }
                        out
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap_or_else(|p| std::panic::resume_unwind(p))).collect()
        });
        if let Some(error) = errors.into_inner().unwrap_or_else(|p| p.into_inner()).into_iter().next() {
            return Some(error);
        }
        let expected = self.simulate_state(&mut ctx, prefix).expect("the model allows the prefix");
        let fin = match self.model.abstract_state {
            Some(abstraction) => match abstraction(&mut ctx, vec![state.clone()]) {
                Ok(v) => Some(v),
                Err(e) => return Some(format!("raised error: {e}")),
            },
            None => None,
        };
        let mut seen = std::collections::HashSet::new();
        let positions = vec![0; branches.len()];
        if self.linearizes(&mut ctx, branches, &history, &mut seen, positions, expected, fin.as_ref(), &state) {
            return None;
        }
        let mut observed = Vec::new();
        for (i, branch) in branches.iter().enumerate() {
            for (k, (index, _)) in branch.iter().enumerate() {
                observed.push(format!(
                    "{}: {}() returned {}",
                    branch_name(i),
                    self.commands[*index].name,
                    render(&history[i][k].2)
                ));
            }
        }
        Some(format!("no order of the parallel calls agrees with the model ({})", observed.join("; ")))
    }

    // Starts the system and runs the prefix's commands, giving the state.
    fn run_prefix(&self, ctx: &mut Context, prefix: &ModelRun) -> Result<Value> {
        let state = (self.model.start[0])(ctx, prefix.0.clone())?;
        for (index, args) in &prefix.1 {
            let command = &self.commands[*index];
            let mut full = args.clone();
            full.insert(command.state, state.clone());
            (command.run)(ctx, full)?;
        }
        Ok(state)
    }

    /// A Wing-Gong search: linearize, next, a call no pending call on
    /// another thread returned before; memoized on positions and the model
    /// state.
    #[allow(clippy::too_many_arguments)]
    fn linearizes(
        &self,
        ctx: &mut Context,
        branches: &[ModelBranch],
        history: &[Vec<ParallelCall>],
        seen: &mut std::collections::HashSet<(Vec<usize>, String)>,
        positions: Vec<usize>,
        model_state: Value,
        fin: Option<&Value>,
        state: &Value,
    ) -> bool {
        if !seen.insert((positions.clone(), render(&model_state))) {
            return false;
        }
        if positions.iter().zip(branches).all(|(k, b)| *k == b.len()) {
            if let Some(fin) = fin {
                if !matches!(compare_values(fin, &model_state), Ok(std::cmp::Ordering::Equal)) {
                    return false;
                }
            }
            for (kind, invariant) in &self.invariants {
                let subject = if kind == "model" { &model_state } else { state };
                if !matches!(invariant(ctx, vec![subject.clone()]).and_then(|v| v.boolean()), Ok(true)) {
                    return false;
                }
            }
            return true;
        }
        for (i, branch) in branches.iter().enumerate() {
            let k = positions[i];
            if k == branch.len() {
                continue;
            }
            let called = history[i][k].0;
            if (0..branches.len()).any(|j| j != i && positions[j] < branches[j].len() && history[j][positions[j]].1 < called) {
                continue;
            }
            let (index, args) = &branch[k];
            let command = &self.commands[*index];
            let (after, wanted) = match step_model(command, ctx, args, model_state.clone()) {
                Ok(stepped) => stepped,
                Err(ModelFault::Invalid) => continue,
                Err(ModelFault::Error(e)) => panic!("model {}: {e}", self.name),
            };
            if !command.unit && !matches!(compare_values(&history[i][k].2, &wanted), Ok(std::cmp::Ordering::Equal)) {
                continue;
            }
            if self.linearizes(ctx, branches, history, seen, advanced(&positions, i), after, fin, state) {
                return true;
            }
        }
        false
    }

    fn parallel_fails(&self, case: &ParallelCase, repeats: u64, shake: u64) -> Option<String> {
        (0..repeats).find_map(|attempt| self.execute_parallel(case, shake.wrapping_add(attempt)))
    }

    fn shrink_parallel(
        &self,
        mut case: ParallelCase,
        mut failure: String,
        repeats: u64,
        mut budget: i64,
        shake: u64,
    ) -> (ParallelCase, String) {
        'shrinking: while budget > 0 {
            let (prefix, branches) = &case;
            let mut candidates: Vec<ParallelCase> = Vec::new();
            for k in 0..prefix.1.len() {
                let mut steps = prefix.1.clone();
                steps.remove(k);
                candidates.push(((prefix.0.clone(), steps), branches.clone()));
            }
            for i in 0..branches.len() {
                for k in 0..branches[i].len() {
                    let mut shorter = branches.clone();
                    shorter[i].remove(k);
                    candidates.push((prefix.clone(), shorter));
                }
            }
            let mut improved = false;
            for candidate in candidates {
                budget -= 1;
                if budget <= 0 {
                    break 'shrinking;
                }
                if !self.parallel_allowed(&candidate.0, &candidate.1) {
                    continue;
                }
                if let Some(found) = self.parallel_fails(&candidate, repeats, shake) {
                    case = candidate;
                    failure = found;
                    improved = true;
                    break;
                }
            }
            if !improved {
                break;
            }
        }
        (case, failure)
    }

    fn describe_parallel(&self, case: &ParallelCase) -> String {
        let describe = |steps: &ModelBranch| {
            let text = steps
                .iter()
                .map(|(i, args)| {
                    format!("{}({})", self.commands[*i].name, args.iter().map(render).collect::<Vec<_>>().join(", "))
                })
                .collect::<Vec<_>>()
                .join("; ");
            if text.is_empty() { "nothing".to_string() } else { text }
        };
        let parts: Vec<String> =
            case.1.iter().enumerate().map(|(i, b)| format!("{}: {}", branch_name(i), describe(b))).collect();
        let (last, rest) = parts.split_last().map(|(l, r)| (l.as_str(), r)).unwrap_or(("", &[]));
        format!("{}, then {} and {} at the same time", self.describe_run(&case.0), rest.join(", "), last)
    }
}

/// Checks a shared model's histories under concurrency (50 cases of three
/// branches, each case run 10 times, seeded by LAWSPEC_SEED); a failure
/// names the smallest failing case found.
pub fn check_model_parallel(model: &Model) -> std::result::Result<(), String> {
    let seed = std::env::var("LAWSPEC_SEED").ok().and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0);
    check_model_parallel_with(model, 50, 10, 300, seed, PARALLEL_THREADS, PARALLEL_BRANCH)
}

/// check_model_parallel with every parameter given.
pub fn check_model_parallel_with(
    model: &Model,
    cases: u64,
    repeats: u64,
    max_shrinks: i64,
    seed: u64,
    threads: usize,
    branch_length: u64,
) -> std::result::Result<(), String> {
    let machine = Machine::new(model);
    let mut random = SplitMix64::new(seed ^ 0x5BD1E995);
    for case_number in 0..cases {
        let case = machine.generate_parallel(&mut random, 1 + (case_number % 8) as i64, threads, branch_length);
        let shake = random.next();
        if let Some(failure) = machine.parallel_fails(&case, repeats, shake) {
            let (case, failure) = machine.shrink_parallel(case, failure, (repeats / 2).max(2), max_shrinks, shake);
            return Err(format!(
                "model {} is not linearizable: {}: {}",
                machine.name,
                machine.describe_parallel(&case),
                failure
            ));
        }
    }
    Ok(())
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
