mod lawspec_runtime;
use lawspec_runtime as ls;
use ls::{ConstructorSchema, DataSchema, Schema, TypeRef, Value};

fn named(name: &'static str, args: Vec<TypeRef>) -> TypeRef {
    TypeRef::named(name, args)
}
fn int() -> TypeRef {
    named("Int8", vec![])
}
fn number(n: i32) -> Value {
    Value::Integer(n.into())
}
fn data(tag: &str, fields: Vec<Value>) -> Value {
    Value::Data(tag.into(), fields)
}
fn variant(tag: &'static str, fields: Vec<TypeRef>) -> ConstructorSchema {
    ConstructorSchema { tag, fields }
}
fn schema() -> Schema {
    let a = TypeRef::Parameter(0);
    let b = TypeRef::Parameter(1);
    Schema::new(vec![
        DataSchema {
            name: "Tree",
            parameters: 1,
            constructors: vec![
                variant("Tree::Leaf", vec![a.clone(), int()]),
                variant(
                    "Tree::Forest",
                    vec![named("List", vec![named("Tree", vec![a.clone()])])],
                ),
            ],
        },
        DataSchema {
            name: "Pair",
            parameters: 2,
            constructors: vec![variant("Pair::Pair", vec![a.clone(), b.clone()])],
        },
        DataSchema {
            name: "Nest",
            parameters: 1,
            constructors: vec![
                variant("Nest::Stop", vec![a.clone()]),
                variant(
                    "Nest::Next",
                    vec![named("Nest", vec![named("List", vec![a.clone()])])],
                ),
            ],
        },
        DataSchema {
            name: "Phantom",
            parameters: 1,
            constructors: vec![variant("Phantom::Tag", vec![])],
        },
        DataSchema {
            name: "A",
            parameters: 2,
            constructors: vec![
                variant("A::End", vec![a.clone()]),
                variant("A::Next", vec![named("B", vec![b.clone(), a.clone()])]),
            ],
        },
        DataSchema {
            name: "B",
            parameters: 2,
            constructors: vec![
                variant("B::End", vec![a.clone()]),
                variant("B::Next", vec![named("A", vec![b, a.clone()])]),
            ],
        },
        DataSchema {
            name: "Wrapped",
            parameters: 1,
            constructors: vec![variant(
                "Wrapped::Wrap",
                vec![named(
                    "Nullable",
                    vec![named("Optional", vec![named("List", vec![a])])],
                )],
            )],
        },
    ])
    .unwrap()
}
fn positive(_: usize, value: Value, _: &mut ls::Context) -> ls::Result<Value> {
    Ok(Value::Bool(value.integer()? > 0.into()))
}
fn check(
    ty: TypeRef,
    value: Value,
    count: usize,
    predicate: impl FnMut(usize, Value, &mut ls::Context) -> ls::Result<Value>,
) -> ls::Result<bool> {
    schema()
        .all_payloads_with_context(
            value,
            &ty,
            count,
            64,
            &mut ls::Context::default(),
            predicate,
        )?
        .boolean()
}
fn leaf(n: i32) -> Value {
    data("Tree::Leaf", vec![number(n), number(-128)])
}

#[test]
fn payload_recursive_leaves_and_fixed_fields() -> ls::Result<()> {
    for bits in [32, 64] {
        for (n, expected) in [(1, true), (0, false)] {
            let mut value = leaf(n);
            for _ in 0..40 {
                value = data("Tree::Forest", vec![Value::List(vec![value])]);
            }
            assert_eq!(
                schema()
                    .all_payloads_with_context(
                        value,
                        &named("Tree", vec![int()]),
                        1,
                        bits,
                        &mut ls::Context::default(),
                        positive
                    )?
                    .boolean()?,
                expected
            );
        }
    }
    Ok(())
}
#[test]
fn payload_independent_roles_and_mutual_swaps() -> ls::Result<()> {
    let roles = |index, value: Value, _: &mut ls::Context| {
        Ok(Value::Bool(if index == 0 {
            value.integer()? > 0.into()
        } else {
            value.integer()? < 0.into()
        }))
    };
    for (first, second, expected) in [(1, -1, true), (-1, 1, false), (1, 1, false)] {
        assert_eq!(
            check(
                named("Pair", vec![int(), int()]),
                data("Pair::Pair", vec![number(first), number(second)]),
                2,
                roles
            )?,
            expected
        );
    }
    for (n, expected) in [(-1, true), (1, false)] {
        assert_eq!(
            check(
                named("A", vec![int(), int()]),
                data("A::Next", vec![data("B::End", vec![number(n)])]),
                2,
                roles
            )?,
            expected
        );
    }
    Ok(())
}
#[test]
fn payload_growing_arguments_and_nested_presence() -> ls::Result<()> {
    for (n, expected) in [(1, true), (0, false)] {
        let value = data(
            "Nest::Next",
            vec![data(
                "Nest::Next",
                vec![data(
                    "Nest::Stop",
                    vec![Value::List(vec![Value::List(vec![number(n)])])],
                )],
            )],
        );
        assert_eq!(
            check(named("Nest", vec![int()]), value, 1, positive)?,
            expected
        );
        let value = data(
            "Wrapped::Wrap",
            vec![Value::Nullable(Some(Box::new(Value::Optional(Some(
                Box::new(Value::List(vec![number(n)])),
            )))))],
        );
        assert_eq!(
            check(named("Wrapped", vec![int()]), value, 1, positive)?,
            expected
        );
    }
    Ok(())
}
#[test]
fn payload_vacuity_and_whole_argument_semantics() -> ls::Result<()> {
    for (ty, value) in [
        (named("Phantom", vec![int()]), data("Phantom::Tag", vec![])),
        (
            named("Tree", vec![int()]),
            data("Tree::Forest", vec![Value::List(vec![])]),
        ),
        (named("Maybe", vec![int()]), Value::Maybe(None)),
        (named("Nullable", vec![int()]), Value::Nullable(None)),
        (named("Optional", vec![int()]), Value::Optional(None)),
    ] {
        assert!(check(ty, value, 1, |_, _, _| panic!(
            "unstored predicate invoked"
        ))?);
    }
    assert!(check(
        named("Tree", vec![named("Optional", vec![int()])]),
        data("Tree::Leaf", vec![Value::Optional(None), number(0)]),
        1,
        |_, value, _| Ok(Value::Bool(matches!(value, Value::Optional(None))))
    )?);
    assert!(check(
        named("Either", vec![int(), int()]),
        Value::Right(Box::new(number(1))),
        2,
        |index, value, ctx| {
            assert_eq!(index, 1);
            positive(index, value, ctx)
        }
    )?);
    Ok(())
}
#[test]
fn payload_short_circuit_errors_and_validation_order() -> ls::Result<()> {
    let ty = named("Tree", vec![int()]);
    let value = data("Tree::Forest", vec![Value::List(vec![leaf(0), leaf(1)])]);
    let mut visits = 0;
    assert!(!check(ty.clone(), value.clone(), 1, |i, value, ctx| {
        visits += 1;
        positive(i, value, ctx)
    })?);
    assert_eq!(visits, 1);
    let error = check(ty.clone(), value, 1, |_, _, _| Err("fault".into())).unwrap_err();
    assert!(error.contains("Tree::Forest field 0: List element 0: Tree::Leaf field 0: fault"));
    assert!(
        check(ty.clone(), leaf(1), 1, |_, _, _| Ok(number(1)))
            .unwrap_err()
            .contains("Bool")
    );
    visits = 0;
    assert!(
        check(
            ty.clone(),
            data("Tree::Leaf", vec![number(1), number(128)]),
            1,
            |_, _, _| {
                visits += 1;
                Ok(Value::Bool(true))
            }
        )
        .is_err()
    );
    assert_eq!(visits, 0);
    assert!(
        check(ty, leaf(1), 0, positive)
            .unwrap_err()
            .contains("arity")
    );
    assert!(
        check(int(), number(1), 0, positive)
            .unwrap_err()
            .contains("data type")
    );
    Ok(())
}
#[test]
fn payload_shares_symbol_context_without_reborrowing_conflicts() -> ls::Result<()> {
    let mut context = ls::Context::default();
    let symbol = context.symbol("shared", "description");
    let value = Value::List(vec![Value::Symbol(symbol)]);
    assert!(
        schema()
            .all_payloads_with_context(
                value,
                &named("List", vec![named("Symbol", vec![])]),
                1,
                64,
                &mut context,
                |_, value, ctx| {
                    Ok(Value::Bool(
                        value == Value::Symbol(ctx.symbol("shared", "description")),
                    ))
                }
            )?
            .boolean()?
    );
    Ok(())
}

#[test]
fn payload_constructor_validation_precedes_callbacks() -> ls::Result<()> {
    let schema = Schema::with_contracts(
        vec![DataSchema {
            name: "Checked",
            parameters: 1,
            constructors: vec![variant("Checked::Value", vec![TypeRef::Parameter(0)])],
        }],
        vec![ls::ConstructorContract {
            tag: "Checked::Value",
            predicates: vec![|_, _, fields, _, _| Ok(fields[0].integer()? > 0.into())],
        }],
    )?;
    let mut visits = 0;
    let error = schema
        .all_payloads_with_context(
            data("Checked::Value", vec![number(0)]),
            &named("Checked", vec![int()]),
            1,
            64,
            &mut ls::Context::default(),
            |_, _, _| {
                visits += 1;
                Ok(Value::Bool(true))
            },
        )
        .unwrap_err();
    assert!(error.contains("field refinement 1 failed"));
    assert_eq!(visits, 0);
    Ok(())
}
