mod lawspec_runtime;
mod lawspec_schema;
mod lawspec_strategies;

use lawspec_runtime as ls;
use lawspec_strategies as generators;
use proptest::prelude::*;
use proptest::strategy::ValueTree;
use proptest::test_runner::{Config, TestError, TestRunner};

fn runner() -> TestRunner {
    TestRunner::deterministic()
}

#[test]
fn native_shrinking_preserves_dependent_fields() -> ls::Result<()> {
    let schema = lawspec_schema::schema()?;
    let ty = ls::TypeRef::named("native.fields::type::Gap", vec![]);
    assert!(generators::schema_strategy(&schema, &ty, MACHINE_BITS, 3).is_err());
    let context = ls::Context::default();
    let strategy =
        generators::checked_schema_strategy(&schema, &ty, MACHINE_BITS, 3, &context, vec![])?;
    let mut runner = runner();
    for _ in 0..100 {
        let mut tree = strategy.new_tree(&mut runner).unwrap();
        for _ in 0..1024 {
            let value = tree.current()?;
            schema.validate_with_context(value, &ty, MACHINE_BITS, &mut context.clone())?;
            if !tree.simplify() {
                break;
            }
        }
    }
    Ok(())
}

#[test]
fn nested_symbol_witnesses_keep_native_length_shrinking() -> ls::Result<()> {
    let schema = lawspec_schema::schema()?;
    let element = ls::TypeRef::named("native.fields::type::Identity", vec![]);
    let ty = ls::TypeRef::named("List", vec![element]);
    let mut context = ls::Context::default();
    let symbol = context.symbol("fixture", "same");
    let value = ls::Value::Data(
        "native.fields::type::Identity::Identity".into(),
        vec![ls::Value::Symbol(symbol)],
    );
    let witness = ls::Value::List(vec![value.clone(); 3]);
    let strategy = generators::checked_schema_strategy(
        &schema,
        &ty,
        MACHINE_BITS,
        7,
        &context,
        vec![witness.clone()],
    )?;
    let result = runner().run(&strategy, |candidate| {
        let value = candidate.map_err(TestCaseError::fail)?;
        schema
            .validate_with_context(value.clone(), &ty, MACHINE_BITS, &mut context.clone())
            .map_err(TestCaseError::fail)?;
        let ls::Value::List(values) = value else {
            unreachable!()
        };
        prop_assert!(values.len() < 2);
        Ok(())
    });
    let Err(TestError::Fail(_, Ok(ls::Value::List(values)))) = result else {
        panic!("expected a shrunk counterexample: {result:?}");
    };
    assert_eq!(values.len(), 2);
    assert!(
        generators::checked_schema_strategy(
            &schema,
            &ty,
            MACHINE_BITS,
            6,
            &context,
            vec![witness.clone()],
        )
        .is_err()
    );
    assert!(
        generators::checked_schema_strategy(
            &schema,
            &ty,
            MACHINE_BITS,
            7,
            &ls::Context::default(),
            vec![witness],
        )
        .is_err()
    );
    Ok(())
}

fn rejecting_schema(predicate: ls::FieldPredicate) -> ls::Result<ls::Schema> {
    ls::Schema::with_contracts(
        vec![ls::DataSchema {
            name: "Empty",
            parameters: 0,
            constructors: vec![ls::ConstructorSchema {
                tag: "Empty",
                fields: vec![],
            }],
        }],
        vec![ls::ConstructorContract {
            tag: "Empty",
            predicates: vec![predicate],
        }],
    )
}

#[test]
fn impossible_branches_do_not_trap_the_enclosing_sum() -> ls::Result<()> {
    let schema = rejecting_schema(|_, _, _, _, _| Ok(false))?;
    let ty = ls::TypeRef::named(
        "Either",
        vec![
            ls::TypeRef::named("Empty", vec![]),
            ls::TypeRef::named("Bool", vec![]),
        ],
    );
    let strategy = generators::checked_schema_strategy(
        &schema,
        &ty,
        MACHINE_BITS,
        2,
        &ls::Context::default(),
        vec![],
    )?;
    let mut runner = runner();
    for _ in 0..100 {
        assert!(matches!(
            strategy.new_tree(&mut runner).unwrap().current()?,
            ls::Value::Right(_)
        ));
    }
    let ty = ls::TypeRef::named("Empty", vec![]);
    let strategy = generators::checked_schema_strategy(
        &schema,
        &ty,
        MACHINE_BITS,
        1,
        &ls::Context::default(),
        vec![],
    )?;
    let mut runner = TestRunner::new(Config {
        max_local_rejects: 16,
        ..Config::default()
    });
    assert!(strategy.new_tree(&mut runner).is_err());
    Ok(())
}

#[test]
fn evaluator_errors_are_visible_during_generation_and_shrinking() -> ls::Result<()> {
    let schema = rejecting_schema(|_, _, _, _, _| Err("predicate evaluation failed".into()))?;
    let ty = ls::TypeRef::named("Empty", vec![]);
    let strategy = generators::checked_schema_strategy(
        &schema,
        &ty,
        MACHINE_BITS,
        1,
        &ls::Context::default(),
        vec![],
    )?;
    let mut tree = strategy.new_tree(&mut runner()).unwrap();
    assert!(
        tree.current()
            .unwrap_err()
            .contains("predicate evaluation failed")
    );
    tree.simplify();
    assert!(
        tree.current()
            .unwrap_err()
            .contains("predicate evaluation failed")
    );
    Ok(())
}
