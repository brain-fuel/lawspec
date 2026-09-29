use proptest::prelude::*;
use proptest::strategy::ValueTree;
use proptest::test_runner::TestRunner;
use std::sync::atomic::{AtomicUsize, Ordering};

static FACTORY_CALLS: AtomicUsize = AtomicUsize::new(0);

fn integers(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    children: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    assert!(children.is_empty());
    FACTORY_CALLS.fetch_add(1, Ordering::SeqCst);
    Ok((40i32..100)
        .prop_map(|value| lawspec_runtime::Value::Integer(value.into()))
        .boxed())
}

#[test]
fn custom_strategy_is_used_inside_containers_and_retains_shrinking() -> lawspec_runtime::Result<()>
{
    use lawspec_runtime::{Context, Schema, TypeRef, Value};
    let schema = Schema::new(vec![])?;
    let custom = ls_gen::NativeGenerators::new(vec![("Int32", integers)])?;
    let element = TypeRef::named("Int32", vec![]);
    let ty = TypeRef::named("List", vec![element.clone()]);
    let strategy =
        ls_gen::schema_strategy_with_generators(&schema, &ty, 64, 4, &Context::default(), &custom)?;
    let mut runner = TestRunner::deterministic();
    let mut saw_nonempty = false;
    for _ in 0..30 {
        let tree = strategy.new_tree(&mut runner).unwrap();
        let Value::List(values) = tree.current() else {
            panic!("list");
        };
        saw_nonempty |= !values.is_empty();
        for value in values {
            let Value::Integer(value) = value else {
                panic!("integer");
            };
            assert!(value >= 40.into() && value < 100.into());
        }
    }
    assert!(saw_nonempty);
    assert!(FACTORY_CALLS.load(Ordering::SeqCst) > 0);
    let strategy = ls_gen::schema_strategy_with_generators(
        &schema,
        &element,
        64,
        4,
        &Context::default(),
        &custom,
    )?;
    let mut tree = strategy.new_tree(&mut runner).unwrap();
    while tree.simplify() {}
    assert_eq!(tree.current(), Value::Integer(40.into()));
    Ok(())
}

fn invalid(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    _: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    Ok(Just(lawspec_runtime::Value::Bool(true)).boxed())
}

#[test]
#[should_panic(expected = "native generator")]
fn invalid_custom_samples_fail_instead_of_becoming_rejections() {
    use lawspec_runtime::{Context, Schema, TypeRef};
    let schema = Schema::new(vec![]).unwrap();
    let custom = ls_gen::NativeGenerators::new(vec![("Int32", invalid)]).unwrap();
    let strategy = ls_gen::schema_strategy_with_generators(
        &schema,
        &TypeRef::named("Int32", vec![]),
        64,
        4,
        &Context::default(),
        &custom,
    )
    .unwrap();
    strategy
        .new_tree(&mut TestRunner::deterministic())
        .unwrap()
        .current();
}

#[derive(Debug)]
struct InvalidShrink;
#[derive(Debug)]
struct InvalidTree(bool);
impl Strategy for InvalidShrink {
    type Tree = InvalidTree;
    type Value = lawspec_runtime::Value;
    fn new_tree(&self, _: &mut TestRunner) -> proptest::strategy::NewTree<Self> {
        Ok(InvalidTree(false))
    }
}
impl ValueTree for InvalidTree {
    type Value = lawspec_runtime::Value;
    fn current(&self) -> Self::Value {
        if self.0 {
            Self::Value::Bool(false)
        } else {
            Self::Value::Integer(42.into())
        }
    }
    fn simplify(&mut self) -> bool {
        if self.0 {
            false
        } else {
            self.0 = true;
            true
        }
    }
    fn complicate(&mut self) -> bool {
        false
    }
}
fn invalid_shrink(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    _: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    Ok(InvalidShrink.boxed())
}

#[test]
#[should_panic(expected = "native generator")]
fn invalid_shrinks_fail_instead_of_being_hidden() {
    use lawspec_runtime::{Context, Schema, TypeRef, Value};
    let schema = Schema::new(vec![]).unwrap();
    let custom = ls_gen::NativeGenerators::new(vec![("Int32", invalid_shrink)]).unwrap();
    let strategy = ls_gen::schema_strategy_with_generators(
        &schema,
        &TypeRef::named("Int32", vec![]),
        64,
        4,
        &Context::default(),
        &custom,
    )
    .unwrap();
    let mut tree = strategy.new_tree(&mut TestRunner::deterministic()).unwrap();
    assert_eq!(tree.current(), Value::Integer(42.into()));
    assert!(tree.simplify());
    tree.current();
}

fn boxes(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    mut children: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    assert_eq!(children.len(), 1);
    Ok(children
        .pop()
        .unwrap()
        .prop_map(|value| {
            lawspec_runtime::Value::Data("native.shapes::type::Box::Box".into(), vec![value])
        })
        .boxed())
}

#[test]
fn generic_factory_composes_child_strategies_and_their_shrinkers() -> lawspec_runtime::Result<()> {
    use lawspec_runtime::{Context, TypeRef, Value};
    let schema = lawspec_example::lawspec_schema::schema()?;
    let custom = ls_gen::NativeGenerators::new(vec![
        ("native.shapes::type::Box", boxes),
        ("Int32", integers),
    ])?;
    let ty = TypeRef::named(
        "native.shapes::type::Box",
        vec![TypeRef::named("Int32", vec![])],
    );
    let strategy =
        ls_gen::schema_strategy_with_generators(&schema, &ty, 64, 8, &Context::default(), &custom)?;
    let mut tree = strategy.new_tree(&mut TestRunner::deterministic()).unwrap();
    while tree.simplify() {}
    let Value::Data(tag, fields) = tree.current() else {
        panic!("box");
    };
    assert_eq!(tag, "native.shapes::type::Box::Box");
    assert_eq!(fields, vec![Value::Integer(40.into())]);
    Ok(())
}

fn empty(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    _: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    Ok(Just(lawspec_runtime::Value::Integer(42.into()))
        .prop_filter("empty custom domain", |_| false)
        .boxed())
}

#[test]
fn exhausted_custom_generator_is_not_replaced_by_a_boundary_witness() -> lawspec_runtime::Result<()>
{
    use lawspec_runtime::{Context, Schema, TypeRef, Value};
    let schema = Schema::new(vec![])?;
    let custom = ls_gen::NativeGenerators::new(vec![("Int32", empty)])?;
    let strategy = ls_gen::checked_schema_strategy_with_generators(
        &schema,
        &TypeRef::named("Int32", vec![]),
        64,
        8,
        &Context::default(),
        vec![Value::Integer(1.into())],
        &custom,
    )?;
    let mut runner = TestRunner::new(proptest::test_runner::Config {
        max_local_rejects: 8,
        max_global_rejects: 8,
        ..Default::default()
    });
    assert!(strategy.new_tree(&mut runner).is_err());
    Ok(())
}

fn phantom_schema() -> lawspec_runtime::Result<lawspec_runtime::Schema> {
    use lawspec_runtime::{ConstructorSchema, DataSchema, Schema, TypeRef};
    Schema::new(vec![
        DataSchema {
            name: "Empty",
            parameters: 0,
            constructors: vec![],
        },
        DataSchema {
            name: "Phantom",
            parameters: 1,
            constructors: vec![ConstructorSchema {
                tag: "Phantom::Phantom",
                fields: vec![TypeRef::named("Int32", vec![])],
            }],
        },
    ])
}

fn phantoms(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    children: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    assert_eq!(children.len(), 1);
    Ok((40i32..100)
        .prop_map(|value| {
            lawspec_runtime::Value::Data(
                "Phantom::Phantom".into(),
                vec![lawspec_runtime::Value::Integer(value.into())],
            )
        })
        .boxed())
}

fn demand_empty(
    _: &lawspec_runtime::Schema,
    _: &lawspec_runtime::TypeRef,
    _: u32,
    _: &lawspec_runtime::Context,
    mut children: Vec<BoxedStrategy<lawspec_runtime::Value>>,
) -> lawspec_runtime::Result<BoxedStrategy<lawspec_runtime::Value>> {
    Ok(children
        .pop()
        .unwrap()
        .prop_map(|_| {
            lawspec_runtime::Value::Data(
                "Phantom::Phantom".into(),
                vec![lawspec_runtime::Value::Integer(40.into())],
            )
        })
        .boxed())
}

#[test]
fn unused_empty_parameter_retains_native_shrinking() -> lawspec_runtime::Result<()> {
    use lawspec_runtime::{Context, TypeRef, Value};
    let schema = phantom_schema()?;
    let native = ls_gen::NativeGenerators::new(vec![("Phantom", phantoms)])?;
    let ty = TypeRef::named("Phantom", vec![TypeRef::named("Empty", vec![])]);
    for bits in [32, 64] {
        let strategy = ls_gen::schema_strategy_with_generators(
            &schema,
            &ty,
            bits,
            32,
            &Context::default(),
            &native,
        )?;
        let mut tree = strategy.new_tree(&mut TestRunner::deterministic()).unwrap();
        while tree.simplify() {}
        assert_eq!(
            tree.current(),
            Value::Data("Phantom::Phantom".into(), vec![Value::Integer(40.into())])
        );
    }
    Ok(())
}

#[test]
fn demanding_empty_parameter_cannot_produce_a_sample() -> lawspec_runtime::Result<()> {
    use lawspec_runtime::{Context, TypeRef};
    let schema = phantom_schema()?;
    let native = ls_gen::NativeGenerators::new(vec![("Phantom", demand_empty)])?;
    let ty = TypeRef::named("Phantom", vec![TypeRef::named("Empty", vec![])]);
    let strategy = ls_gen::schema_strategy_with_generators(
        &schema,
        &ty,
        64,
        32,
        &Context::default(),
        &native,
    )?;
    let mut runner = TestRunner::new(proptest::test_runner::Config {
        max_local_rejects: 8,
        max_global_rejects: 8,
        ..Default::default()
    });
    assert!(strategy.new_tree(&mut runner).is_err());
    let root = ls_gen::schema_strategy_with_generators(
        &schema,
        &TypeRef::named("Empty", vec![]),
        64,
        32,
        &Context::default(),
        &native,
    );
    assert!(root.is_err());
    Ok(())
}
