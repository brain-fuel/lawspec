//! Proptest support, separate from the reusable numeric runtime.
use crate::lawspec_runtime::{self as ls, IntoValue, Value};
use proptest::prelude::*;

pub fn strategy(name: &str) -> ls::Result<BoxedStrategy<Value>> {
    strategy_with_profile(name, usize::BITS)
}

fn scalar_strategy(name: &str) -> ls::Result<BoxedStrategy<Value>> {
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
    if let Some(inner) = name.strip_prefix("List ") {
        return Ok(
            proptest::collection::vec(strategy_with_profile(inner, bits)?, 0..65)
                .prop_map(Value::List)
                .boxed(),
        );
    }
    if let Some(inner) = name.strip_prefix("Maybe ") {
        return Ok(proptest::option::of(strategy_with_profile(inner, bits)?)
            .prop_map(|x| Value::Maybe(x.map(Box::new)))
            .boxed());
    }
    if let Some(arguments) = name.strip_prefix("Either ") {
        let (left, right) = ls::either_types(arguments)?;
        return Ok(prop_oneof![
            strategy_with_profile(left, bits)?.prop_map(|x| Value::Left(Box::new(x))),
            strategy_with_profile(right, bits)?.prop_map(|x| Value::Right(Box::new(x)))
        ]
        .boxed());
    }
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
    scalar_strategy(match (name, bits) {
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
    pub error: Option<String>,
}
pub fn seeded(strategy: BoxedStrategy<Value>, seeds: Vec<Value>) -> BoxedStrategy<Value> {
    if seeds.is_empty() {
        strategy
    } else {
        prop_oneof![strategy, proptest::sample::select(seeds)].boxed()
    }
}

/// Compose native proptest generators from instantiated Core data schemas.
/// The structural budget limits samples, not the mathematical input domain.
/// Memoization shares strategies for repeated fields in recursive products.
pub fn schema_strategy(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
) -> ls::Result<BoxedStrategy<Value>> {
    if schema.has_contracts() {
        return Err(
            "constructor contracts require checked_schema_strategy and a Symbol context".into(),
        );
    }
    shape_strategy(schema, ty, bits, budget, Default::default())
}

type Witnesses = std::collections::HashMap<ls::TypeRef, Vec<Value>>;

fn value_cost(value: &Value) -> usize {
    match value {
        Value::Data(_, fields) | Value::List(fields) => {
            1 + fields.iter().map(value_cost).sum::<usize>()
        }
        Value::Maybe(Some(value))
        | Value::Nullable(Some(value))
        | Value::Optional(Some(value))
        | Value::Left(value)
        | Value::Right(value) => 1 + value_cost(value),
        _ => 1,
    }
}

// Witnesses are validated before traversal. Keep their instantiated types so a
// Symbol seed cannot leak into unrelated fields with the same representation.
fn collect_witnesses(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    value: &Value,
    seeds: &mut Witnesses,
) -> ls::Result<()> {
    // Builtin containers must use their native structural generators so a
    // witness list can still shrink its length. Seed payloads recursively;
    // retain named values as fallbacks for uneven recursive node allocations.
    if !matches!(
        value,
        Value::List(_)
            | Value::Maybe(_)
            | Value::Nullable(_)
            | Value::Optional(_)
            | Value::Left(_)
            | Value::Right(_)
    ) {
        seeds.entry(ty.clone()).or_default().push(value.clone());
    }
    if let Some(constructors) = schema.constructor_fields(ty)? {
        let Value::Data(tag, fields) = value else {
            return Err("invalid data witness".into());
        };
        let constructor = constructors
            .iter()
            .find(|c| c.tag == tag)
            .ok_or("unknown witness constructor")?;
        for (field_type, field) in constructor.fields.iter().zip(fields) {
            collect_witnesses(schema, field_type, field, seeds)?;
        }
    } else if let ls::TypeRef::Named(_, arguments) = ty {
        match value {
            Value::List(values) => {
                for value in values {
                    collect_witnesses(schema, &arguments[0], value, seeds)?;
                }
            }
            Value::Maybe(Some(value))
            | Value::Nullable(Some(value))
            | Value::Optional(Some(value))
            | Value::Left(value) => {
                collect_witnesses(schema, &arguments[0], value, seeds)?;
            }
            Value::Right(value) => collect_witnesses(schema, &arguments[1], value, seeds)?,
            _ => {}
        }
    }
    Ok(())
}

/// Reject only false predicates, across whole candidates rather than individual
/// branches. Native proptest filtering bounds retries and preserves shrinking.
/// Evaluation errors remain Err values that the property must report as failures.
/// Context clones preserve Symbol identity without mutating it during shrinking.
pub fn checked_schema_strategy(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
    context: &ls::Context,
    witnesses: Vec<Value>,
) -> ls::Result<BoxedStrategy<ls::Result<Value>>> {
    let mut seeds = Witnesses::new();
    for witness in witnesses {
        let value = schema.validate_with_context(witness, ty, bits, &mut context.clone())?;
        if value_cost(&value) > budget {
            return Err("constructor witness exceeds structural node budget".into());
        }
        collect_witnesses(schema, ty, &value, &mut seeds)?;
    }
    let strategy = shape_strategy(schema, ty, bits, budget, seeds)?;
    let schema = schema.clone();
    let ty = ty.clone();
    let context = context.clone();
    Ok(strategy
        .prop_filter_map("constructor field refinement", move |value| {
            match schema.check_with_context(value, &ty, bits, &mut context.clone()) {
                Ok(ls::ValueCheck::Accepted(value)) => Some(Ok(value)),
                Ok(ls::ValueCheck::Rejected(_)) => None,
                Err(error) => Some(Err(error)),
            }
        })
        .boxed())
}

fn shape_strategy(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
    witnesses: Witnesses,
) -> ls::Result<BoxedStrategy<Value>> {
    type Request = (ls::TypeRef, usize);
    struct Builder<'a> {
        schema: &'a ls::Schema,
        bits: u32,
        witnesses: Witnesses,
        inhabited: std::collections::HashMap<Request, bool>,
        generators: std::collections::HashMap<Request, BoxedStrategy<Value>>,
    }

    impl Builder<'_> {
        fn can_generate(&mut self, ty: &ls::TypeRef, budget: usize) -> ls::Result<bool> {
            if budget == 0 {
                return Ok(false);
            }
            let key = (ty.clone(), budget);
            if let Some(result) = self.inhabited.get(&key) {
                return Ok(*result);
            }
            let result = if let Some(constructors) = self.schema.constructor_fields(ty)? {
                let mut found = false;
                for constructor in constructors {
                    if self.allocate(&constructor.fields, budget - 1)?.is_some() {
                        found = true;
                        break;
                    }
                }
                found
            } else {
                let ls::TypeRef::Named(name, arguments) = ty else {
                    return Err("uninstantiated generator type".into());
                };
                match (*name, arguments.as_slice()) {
                    ("List" | "Maybe" | "Nullable" | "Optional", [_]) => true,
                    ("Either", [left, right]) => {
                        self.can_generate(left, budget - 1)?
                            || self.can_generate(right, budget - 1)?
                    }
                    (_, []) => true,
                    _ => return Err(format!("unsupported generator type: {ty:?}")),
                }
            };
            self.inhabited.insert(key, result);
            Ok(result)
        }

        fn minimum(&mut self, ty: &ls::TypeRef, limit: usize) -> ls::Result<Option<usize>> {
            for cost in 1..=limit {
                if self.can_generate(ty, cost)? {
                    return Ok(Some(cost));
                }
            }
            Ok(None)
        }

        // Reserve every field's minimum before sharing the remaining nodes.
        // A deep field must not disappear merely because its siblings are small.
        fn allocate(
            &mut self,
            fields: &[ls::TypeRef],
            budget: usize,
        ) -> ls::Result<Option<Vec<usize>>> {
            let mut remaining = budget;
            let mut costs = Vec::new();
            for field in fields {
                let Some(cost) = self.minimum(field, remaining)? else {
                    return Ok(None);
                };
                costs.push(cost);
                remaining -= cost;
            }
            let count = costs.len();
            for (index, cost) in costs.iter_mut().enumerate() {
                *cost += remaining / count + usize::from(index < remaining % count);
            }
            Ok(Some(costs))
        }

        fn generate(
            &mut self,
            ty: &ls::TypeRef,
            budget: usize,
        ) -> ls::Result<BoxedStrategy<Value>> {
            if !self.can_generate(ty, budget)? {
                return Err(format!(
                    "no value within structural node budget {budget}: {ty:?}"
                ));
            }
            let key = (ty.clone(), budget);
            if let Some(cached) = self.generators.get(&key) {
                return Ok(cached.clone());
            }
            let result = if let Some(constructors) = self.schema.constructor_fields(ty)? {
                let mut alternatives = Vec::new();
                for constructor in constructors {
                    let Some(costs) = self.allocate(&constructor.fields, budget - 1)? else {
                        continue;
                    };
                    let mut fields = Just(Vec::<Value>::new()).boxed();
                    for (field, cost) in constructor.fields.iter().zip(costs) {
                        let next = self.generate(field, cost)?;
                        fields = (fields, next)
                            .prop_map(|(mut values, value)| {
                                values.push(value);
                                values
                            })
                            .boxed();
                    }
                    alternatives.push(
                        fields
                            .prop_map(move |fields| ls::construct_data(constructor.tag, fields))
                            .boxed(),
                    );
                }
                proptest::strategy::Union::new(alternatives).boxed()
            } else {
                let ls::TypeRef::Named(name, arguments) = ty else {
                    return Err("uninstantiated generator type".into());
                };
                match (*name, arguments.as_slice()) {
                    ("List", [element]) => {
                        let remaining = budget - 1;
                        let maximum = self
                            .minimum(element, remaining)?
                            .map_or(0, |cost| remaining / cost);
                        let mut lengths = vec![Just(Value::List(vec![])).boxed()];
                        for length in 1..=maximum {
                            let elements = self.generate(element, remaining / length)?;
                            lengths.push(
                                proptest::collection::vec(elements, length..=length)
                                    .prop_map(Value::List)
                                    .boxed(),
                            );
                        }
                        // Native dependent shrinking changes length and then
                        // shrinks elements under the recomputed size bound.
                        (0..=maximum)
                            .prop_flat_map(move |length| lengths[length].clone())
                            .boxed()
                    }
                    ("Maybe" | "Nullable" | "Optional", [element]) => {
                        let values = if self.can_generate(element, budget - 1)? {
                            proptest::option::of(self.generate(element, budget - 1)?).boxed()
                        } else {
                            Just(None).boxed()
                        };
                        let name = *name;
                        values
                            .prop_map(move |value| match name {
                                "Maybe" => Value::Maybe(value.map(Box::new)),
                                "Nullable" => Value::Nullable(value.map(Box::new)),
                                _ => Value::Optional(value.map(Box::new)),
                            })
                            .boxed()
                    }
                    ("Either", [left, right]) => {
                        let mut alternatives = Vec::new();
                        if self.can_generate(left, budget - 1)? {
                            alternatives.push(
                                self.generate(left, budget - 1)?
                                    .prop_map(|value| Value::Left(Box::new(value)))
                                    .boxed(),
                            );
                        }
                        if self.can_generate(right, budget - 1)? {
                            alternatives.push(
                                self.generate(right, budget - 1)?
                                    .prop_map(|value| Value::Right(Box::new(value)))
                                    .boxed(),
                            );
                        }
                        proptest::strategy::Union::new(alternatives).boxed()
                    }
                    (_, []) => strategy_with_profile(name, self.bits)?,
                    _ => return Err(format!("unsupported generator type: {ty:?}")),
                }
            };
            let seeds = self
                .witnesses
                .get(ty)
                .into_iter()
                .flatten()
                .filter(|value| value_cost(value) <= budget)
                .cloned()
                .collect();
            let result = seeded(result, seeds);
            self.generators.insert(key, result.clone());
            Ok(result)
        }
    }

    if !matches!(bits, 32 | 64) {
        return Err("machineBits must be 32 or 64".into());
    }
    Builder {
        schema,
        bits,
        witnesses,
        inhabited: Default::default(),
        generators: Default::default(),
    }
    .generate(ty, budget)
}
