//! Proptest support, separate from the reusable numeric runtime.
use crate::lawspec_runtime::{self as ls, IntoValue, Value};
use proptest::prelude::*;

/// A framework-native factory. Child strategies correspond to type parameters,
/// not constructor fields. Mapping the returned strategy retains its ValueTree.
pub type NativeFactory = fn(
    &ls::Schema,
    &ls::TypeRef,
    u32,
    &ls::Context,
    Vec<BoxedStrategy<Value>>,
) -> ls::Result<BoxedStrategy<Value>>;

#[derive(Default)]
pub struct NativeGenerators {
    factories: std::collections::HashMap<&'static str, NativeFactory>,
}

impl NativeGenerators {
    pub fn new(entries: Vec<(&'static str, NativeFactory)>) -> ls::Result<Self> {
        let mut factories = std::collections::HashMap::new();
        for (name, factory) in entries {
            if name.is_empty() || factories.insert(name, factory).is_some() {
                return Err(format!("duplicate or empty native generator: {name}"));
            }
        }
        Ok(Self { factories })
    }

    fn factory(&self, ty: &ls::TypeRef) -> Option<NativeFactory> {
        match ty {
            ls::TypeRef::Named(name, _) => self.factories.get(name).copied(),
            _ => None,
        }
    }
}

pub fn schema_strategy_with_generators(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
    context: &ls::Context,
    native: &NativeGenerators,
) -> ls::Result<BoxedStrategy<Value>> {
    if schema.has_contracts() {
        return Err("constructor contracts require checked_schema_strategy_with_generators".into());
    }
    shape_strategy_with_generators(
        schema,
        ty,
        bits,
        budget,
        Default::default(),
        context,
        native,
    )
}

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
    checked_schema_strategy_with_generators(
        schema,
        ty,
        bits,
        budget,
        context,
        witnesses,
        &NativeGenerators::default(),
    )
}

pub fn checked_schema_strategy_with_generators(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
    context: &ls::Context,
    witnesses: Vec<Value>,
    native: &NativeGenerators,
) -> ls::Result<BoxedStrategy<ls::Result<Value>>> {
    let mut seeds = Witnesses::new();
    for witness in witnesses {
        let value = schema.validate_with_context(witness, ty, bits, &mut context.clone())?;
        if value_cost(&value) > budget {
            return Err("constructor witness exceeds structural node budget".into());
        }
        collect_witnesses(schema, ty, &value, &mut seeds)?;
    }
    let strategy =
        shape_strategy_with_generators(schema, ty, bits, budget, seeds, context, native)?;
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
    shape_strategy_with_generators(
        schema,
        ty,
        bits,
        budget,
        witnesses,
        &ls::Context::default(),
        &NativeGenerators::default(),
    )
}

fn shape_strategy_with_generators(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
    witnesses: Witnesses,
    context: &ls::Context,
    native: &NativeGenerators,
) -> ls::Result<BoxedStrategy<Value>> {
    type Request = (ls::TypeRef, usize);
    struct Builder<'a> {
        schema: &'a ls::Schema,
        context: &'a ls::Context,
        native: &'a NativeGenerators,
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
            let result = if self.native.factory(ty).is_some() {
                true
            } else if let Some(constructors) = self.schema.constructor_fields(ty)? {
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
            let result = if let Some(factory) = self.native.factory(ty) {
                let ls::TypeRef::Named(_, arguments) = ty else {
                    return Err("uninstantiated native generator type".into());
                };
                let mut children = Vec::new();
                for argument in arguments {
                    let remaining = budget.saturating_sub(1).max(1);
                    let child = if self.can_generate(argument, remaining)? {
                        self.generate(argument, remaining)?
                    } else {
                        // Phantom parameters may be uninhabited. Keep a native
                        // strategy argument that rejects if actually sampled.
                        Just(Value::Unit)
                            .prop_filter(
                                format!("no native generator argument within node budget {remaining}: {argument:?}"),
                                |_| false,
                            )
                            .boxed()
                    };
                    children.push(child);
                }
                let strategy = factory(self.schema, ty, self.bits, self.context, children)?;
                let schema = self.schema.clone();
                let ty = ty.clone();
                let bits = self.bits;
                let context = self.context.clone();
                strategy
                    .prop_map(move |value| {
                        schema
                            .validate_with_context(value, &ty, bits, &mut context.clone())
                            .unwrap_or_else(|error| panic!("native generator {ty:?}: {error}"))
                    })
                    .boxed()
            } else if let Some(constructors) = self.schema.constructor_fields(ty)? {
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
            let result = if self.native.factory(ty).is_some() {
                result
            } else {
                seeded(result, seeds)
            };
            self.generators.insert(key, result.clone());
            Ok(result)
        }
    }

    if !matches!(bits, 32 | 64) {
        return Err("machineBits must be 32 or 64".into());
    }
    Builder {
        schema,
        context,
        native,
        bits,
        witnesses,
        inhabited: Default::default(),
        generators: Default::default(),
    }
    .generate(ty, budget)
}

/// Values whose linear structural measure equals `target`. Each equation holds a
/// constructor's constant followed by the positions of recursive fields whose
/// measures it adds, so the target is solved backwards and split across those
/// fields. Reachability is a least fixpoint per index level and strategies are
/// built bottom-up; generation never filters, and splits shrink toward the first.
pub fn indexed_strategy(
    schema: &ls::Schema,
    ty: &ls::TypeRef,
    bits: u32,
    budget: usize,
    target: &Value,
    equations: &[(&str, &[u64])],
) -> ls::Result<BoxedStrategy<Value>> {
    type Key = (ls::TypeRef, u64);
    struct Variant {
        tag: &'static str,
        fields: Vec<ls::TypeRef>,
        constant: u64,
        positions: Vec<usize>,
    }
    let Value::Integer(target) = target else {
        return Err("index target must be a natural number".into());
    };
    let k: u64 = target
        .to_string()
        .parse()
        .map_err(|_| "index target must be a natural number".to_string())?;
    let equation = |tag: &str| -> ls::Result<(u64, Vec<usize>)> {
        let (_, found) = equations
            .iter()
            .find(|(name, _)| *name == tag)
            .ok_or_else(|| format!("missing index equation for {tag}"))?;
        Ok((found[0], found[1..].iter().map(|p| *p as usize).collect()))
    };
    let mut families: Vec<(ls::TypeRef, Vec<Variant>)> = Vec::new();
    let mut pending = vec![ty.clone()];
    while let Some(next) = pending.pop() {
        if families.iter().any(|(known, _)| *known == next) {
            continue;
        }
        let constructors = schema
            .constructor_fields(&next)?
            .ok_or("indexed generation requires a data type")?;
        let mut variants = Vec::new();
        for constructor in constructors {
            let (constant, positions) = equation(constructor.tag)?;
            pending.extend(positions.iter().map(|p| constructor.fields[*p].clone()));
            variants.push(Variant {
                tag: constructor.tag,
                fields: constructor.fields.clone(),
                constant,
                positions,
            });
        }
        families.push((next, variants));
    }
    let mut plain: std::collections::HashMap<ls::TypeRef, Option<BoxedStrategy<Value>>> =
        std::collections::HashMap::new();
    for (_, variants) in &families {
        for variant in variants {
            for (index, field) in variant.fields.iter().enumerate() {
                if !variant.positions.contains(&index) && !plain.contains_key(field) {
                    let strategy =
                        shape_strategy(schema, field, bits, budget, Witnesses::new()).ok();
                    plain.insert(field.clone(), strategy);
                }
            }
        }
    }
    let index_types = |variant: &Variant| -> Vec<ls::TypeRef> {
        variant
            .positions
            .iter()
            .map(|p| variant.fields[*p].clone())
            .collect()
    };
    let ready = |variant: &Variant| {
        variant.fields.iter().enumerate().all(|(index, field)| {
            variant.positions.contains(&index) || matches!(plain.get(field), Some(Some(_)))
        })
    };
    fn splits(
        table: &std::collections::HashMap<Key, bool>,
        types: &[ls::TypeRef],
        rest: u64,
    ) -> Vec<Vec<u64>> {
        match types {
            [] if rest == 0 => vec![vec![]],
            [] => vec![],
            [only] if *table.get(&(only.clone(), rest)).unwrap_or(&false) => vec![vec![rest]],
            [_] => vec![],
            [first, others @ ..] => (0..=rest)
                .filter(|part| *table.get(&(first.clone(), *part)).unwrap_or(&false))
                .flat_map(|part| {
                    splits(table, others, rest - part)
                        .into_iter()
                        .map(move |mut tail| {
                            tail.insert(0, part);
                            tail
                        })
                })
                .collect(),
        }
    }
    let feasible = |table: &std::collections::HashMap<Key, bool>, variant: &Variant, j: u64| {
        j >= variant.constant
            && ready(variant)
            && !splits(table, &index_types(variant), j - variant.constant).is_empty()
    };
    let mut table: std::collections::HashMap<Key, bool> = std::collections::HashMap::new();
    for j in 0..=k {
        for (family, _) in &families {
            table.insert((family.clone(), j), false);
        }
        loop {
            let mut changed = false;
            for (family, variants) in &families {
                let value = variants.iter().any(|variant| feasible(&table, variant, j));
                if table.insert((family.clone(), j), value) != Some(value) {
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
    }
    if !table.get(&(ty.clone(), k)).copied().unwrap_or(false) {
        return Err(format!("no value of {ty:?} has index {k}"));
    }
    let mut built: std::collections::HashMap<Key, BoxedStrategy<Value>> =
        std::collections::HashMap::new();
    for j in 0..=k {
        for (family, variants) in &families {
            if !table.get(&(family.clone(), j)).copied().unwrap_or(false) {
                continue;
            }
            let mut alternatives = Vec::new();
            for variant in variants {
                if !feasible(&table, variant, j) {
                    continue;
                }
                // Children at this level are only available once built, which
                // excludes self-referential splits that do not consume index.
                let choices: Vec<Vec<u64>> =
                    splits(&table, &index_types(variant), j - variant.constant)
                        .into_iter()
                        .filter(|split| {
                            split
                                .iter()
                                .zip(index_types(variant))
                                .all(|(part, child)| built.contains_key(&(child, *part)))
                        })
                        .collect();
                if choices.is_empty() {
                    continue;
                }
                let available = std::sync::Arc::new(built.clone());
                let fields = variant.fields.clone();
                let positions = variant.positions.clone();
                let plain_fields: Vec<Option<BoxedStrategy<Value>>> = fields
                    .iter()
                    .map(|field| plain.get(field).cloned().flatten())
                    .collect();
                let tag = variant.tag;
                alternatives.push(
                    proptest::sample::select(choices)
                        .prop_flat_map(move |split| {
                            let children: Vec<BoxedStrategy<Value>> = fields
                                .iter()
                                .enumerate()
                                .map(|(index, field)| {
                                    match positions.iter().position(|p| *p == index) {
                                        Some(position) => {
                                            available[&(field.clone(), split[position])].clone()
                                        }
                                        None => plain_fields[index].clone().unwrap(),
                                    }
                                })
                                .collect();
                            children.prop_map(move |values| ls::construct_data(tag, values))
                        })
                        .boxed(),
                );
            }
            if !alternatives.is_empty() {
                built.insert(
                    (family.clone(), j),
                    proptest::strategy::Union::new(alternatives).boxed(),
                );
            }
        }
    }
    built
        .remove(&(ty.clone(), k))
        .ok_or_else(|| format!("no value of {ty:?} has index {k}"))
}
