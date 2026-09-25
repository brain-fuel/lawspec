//! Proptest support, separate from the reusable numeric runtime.
use crate::lawspec_runtime::{self as ls, IntoValue, Value};
use proptest::prelude::*;

pub fn strategy(name: &str) -> ls::Result<BoxedStrategy<Value>> {
    if let Some(inner) = name.strip_prefix("Nullable ") {
        return Ok(proptest::option::of(strategy(inner)?)
            .prop_map(|x| Value::Nullable(x.map(Box::new)))
            .boxed());
    }
    if let Some(inner) = name.strip_prefix("Optional ") {
        return Ok(proptest::option::of(strategy(inner)?)
            .prop_map(|x| Value::Optional(x.map(Box::new)))
            .boxed());
    }
    macro_rules! integer {
        ($t:ty) => {
            any::<$t>().prop_map(IntoValue::into_value).boxed()
        };
    }
    Ok(match name {
        "Bool" => any::<bool>().prop_map(Value::Bool).boxed(),
        "Int8" => integer!(i8),
        "Int16" => integer!(i16),
        "Int32" => integer!(i32),
        "Int64" => integer!(i64),
        "UInt8" => integer!(u8),
        "UInt16" => integer!(u16),
        "UInt32" => integer!(u32),
        "UInt64" => integer!(u64),
        "IntSize" => integer!(isize),
        "UIntSize" | "UIntPtr" => integer!(usize),
        "Integer" | "BigInt" => bigint().prop_map(Value::Integer).boxed(),
        "BigUInt" => proptest::collection::vec(any::<u8>(), 0..65)
            .prop_map(|bytes| {
                Value::Integer(ls::BigInt::from_bytes_le(num_bigint::Sign::Plus, &bytes))
            })
            .boxed(),
        "Decimal" => (bigint(), -100i32..101)
            .prop_map(|(c, e)| Value::Decimal(ls::Decimal::new(c, e.into())))
            .boxed(),
        "Rational" => (bigint(), 1u64..=u64::MAX)
            .prop_map(|(n, d)| Value::Rational(ls::BigRational::new(n, d.into())))
            .boxed(),
        "Float32" => any::<u32>()
            .prop_map(|b| Value::Float32(f32::from_bits(b)))
            .boxed(),
        "Float64" => any::<u64>()
            .prop_map(|b| Value::Float64(f64::from_bits(b)))
            .boxed(),
        "Complex64" => (any::<u32>(), any::<u32>())
            .prop_map(|(r, i)| {
                Value::Complex32(ls::Complex32::new(f32::from_bits(r), f32::from_bits(i)))
            })
            .boxed(),
        "Complex128" => (any::<u64>(), any::<u64>())
            .prop_map(|(r, i)| {
                Value::Complex64(ls::Complex64::new(f64::from_bits(r), f64::from_bits(i)))
            })
            .boxed(),
        "Char" => any::<char>().prop_map(Value::Char).boxed(),
        "CodePoint" => (0u32..=0x10ffff).prop_map(Value::CodePoint).boxed(),
        "CodeUnit16" => any::<u16>().prop_map(Value::CodeUnit16).boxed(),
        "Text" => proptest::collection::vec(any::<char>(), 0..65)
            .prop_map(|cs| Value::Text(cs.into_iter().collect()))
            .boxed(),
        "CodePointText" => proptest::collection::vec(0u32..=0x10ffff, 0..65)
            .prop_map(Value::CodePointText)
            .boxed(),
        "Utf16Text" => proptest::collection::vec(any::<u16>(), 0..65)
            .prop_map(Value::Utf16Text)
            .boxed(),
        "Bytes" => proptest::collection::vec(any::<u8>(), 0..65)
            .prop_map(Value::Bytes)
            .boxed(),
        "Symbol" => any::<u64>()
            .prop_map(|id| Value::Symbol(ls::Symbol::new(format!("symbol-{id}"))))
            .boxed(),
        "Unit" => Just(Value::Unit).boxed(),
        "Null" => Just(Value::Null).boxed(),
        "Undefined" => Just(Value::Undefined).boxed(),
        _ => return Err(format!("no Rust generator for {name}")),
    })
}
fn bigint() -> BoxedStrategy<ls::BigInt> {
    (any::<bool>(), proptest::collection::vec(any::<u8>(), 0..65))
        .prop_map(|(negative, bytes)| {
            ls::BigInt::from_bytes_le(
                if negative {
                    num_bigint::Sign::Minus
                } else {
                    num_bigint::Sign::Plus
                },
                &bytes,
            )
        })
        .boxed()
}
pub fn tuple(types: &[&str]) -> ls::Result<BoxedStrategy<Vec<Value>>> {
    let mut result = Just(Vec::new()).boxed();
    for name in types {
        result = (result, strategy(name)?)
            .prop_map(|(mut xs, x)| {
                xs.push(x);
                xs
            })
            .boxed();
    }
    Ok(result)
}

/// Construct the affine integer domain after preceding inputs are known.
/// An empty continuation returns None so the native flat-map/filter combination
/// retries the preceding inputs and recomputes the domain during shrinking.
pub fn bounded_integer(
    name: &str,
    bounds: Vec<(&str, Value)>,
    machine_bits: u32,
) -> ls::Result<Option<BoxedStrategy<Value>>> {
    use num_traits::{One, Signed, Zero};
    let width = match name {
        "Int8" | "UInt8" => Some(8),
        "Int16" | "UInt16" => Some(16),
        "Int32" | "UInt32" => Some(32),
        "Int64" | "UInt64" => Some(64),
        "IntSize" | "UIntSize" | "UIntPtr" => Some(machine_bits),
        _ => None,
    };
    let unsigned = name.starts_with("UInt") || name == "BigUInt";
    let mut lo = if unsigned {
        Some(ls::BigInt::zero())
    } else {
        width.map(|w| -(ls::BigInt::one() << (w - 1)))
    };
    let mut hi = width.map(|w| (ls::BigInt::one() << (if unsigned { w } else { w - 1 })) - 1u8);
    for (op, value) in bounds {
        let r = value.exact()?;
        let floor = r.floor().to_integer();
        let ceil = r.ceil().to_integer();
        let (lower, upper) = match op {
            ">" => (Some(floor + 1u8), None),
            ">=" => (Some(ceil), None),
            "<" => (None, Some(ceil - 1u8)),
            "<=" => (None, Some(floor)),
            "==" => {
                if !r.is_integer() {
                    return Ok(None);
                }
                let n = r.to_integer();
                (Some(n.clone()), Some(n))
            }
            _ => return Err("invalid planned integer bound".into()),
        };
        if let Some(n) = lower {
            lo = Some(lo.map_or(n.clone(), |old| old.max(n)));
        }
        if let Some(n) = upper {
            hi = Some(hi.map_or(n.clone(), |old| old.min(n)));
        }
    }
    let span = ls::BigInt::one() << 512usize;
    let lower = lo.unwrap_or_else(|| hi.as_ref().map_or(-&span, |upper| upper - &span));
    let upper = hi.unwrap_or_else(|| &lower + &span);
    if lower > upper {
        return Ok(None);
    }
    let count = &upper - &lower + 1u8;
    let offset = lower.clone();
    Ok(Some(
        prop_oneof![
            Just(Value::Integer(lower)),
            Just(Value::Integer(upper)),
            bigint().prop_map(move |n| Value::Integer(&offset + n.abs() % &count))
        ]
        .boxed(),
    ))
}

pub fn strategy_with_profile(name: &str, bits: u32) -> ls::Result<BoxedStrategy<Value>> {
    if let Some(inner) = name.strip_prefix("Nullable ") {
        return Ok(proptest::option::of(strategy_with_profile(inner, bits)?)
            .prop_map(|x| Value::Nullable(x.map(Box::new)))
            .boxed());
    }
    if let Some(inner) = name.strip_prefix("Optional ") {
        return Ok(proptest::option::of(strategy_with_profile(inner, bits)?)
            .prop_map(|x| Value::Optional(x.map(Box::new)))
            .boxed());
    }
    strategy(match (name, bits) {
        ("IntSize", 32) => "Int32",
        ("IntSize", 64) => "Int64",
        ("UIntSize" | "UIntPtr", 32) => "UInt32",
        ("UIntSize" | "UIntPtr", 64) => "UInt64",
        _ => name,
    })
}

#[derive(Clone, Debug, Default)]
pub struct Case {
    pub context: ls::Context,
    pub values: Vec<Value>,
}
pub fn seeded(strategy: BoxedStrategy<Value>, seeds: Vec<Value>) -> BoxedStrategy<Value> {
    if seeds.is_empty() {
        strategy
    } else {
        prop_oneof![strategy, proptest::sample::select(seeds)].boxed()
    }
}
