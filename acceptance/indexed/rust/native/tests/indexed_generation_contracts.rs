#[path = "../src/lawspec_runtime.rs"]
mod lawspec_runtime;
#[path = "support/lawspec_strategies.rs"]
mod ls_gen;

use lawspec_runtime as ls;
use proptest::test_runner::{Config, RngSeed, TestCaseError, TestError, TestRunner};

fn schema(predicate: ls::FieldPredicate) -> ls::Schema {
    ls::Schema::with_contracts(
        vec![ls::DataSchema {
            name: "Bounded",
            parameters: 0,
            constructors: vec![ls::ConstructorSchema {
                tag: "Bounded",
                fields: vec![ls::TypeRef::named("Int8", vec![])],
            }],
        }],
        vec![ls::ConstructorContract { tag: "Bounded", predicates: vec![predicate] }],
    ).unwrap()
}

fn runner() -> TestRunner {
    TestRunner::new(Config {
        cases: 100,
        rng_seed: RngSeed::Fixed(811),
        failure_persistence: None,
        ..Config::default()
    })
}

fn draw(schema: &ls::Schema) -> proptest::strategy::BoxedStrategy<ls::Result<ls::Value>> {
    ls_gen::checked_indexed_strategy(
        schema, &ls::TypeRef::named("Bounded", vec![]), 64, 64,
        &ls::Context::default(), &ls::Value::Integer(0.into()), &[("Bounded", &["c0"])],
    ).unwrap()
}

#[test]
fn indexed_shrinking_keeps_constructor_predicates() {
    let schema = schema(|_, _, fields, _, _| {
        let ls::Value::Integer(n) = &fields[0] else { return Err("integer required".into()); };
        Ok(n >= &3.into())
    });
    let strategy = draw(&schema);
    runner().run(&strategy, |value| {
        let value = value.map_err(TestCaseError::fail)?;
        assert!(matches!(schema.check_with_context(value, &ls::TypeRef::named("Bounded", vec![]),
            64, &mut ls::Context::default()).unwrap(), ls::ValueCheck::Accepted(_)));
        Ok(())
    }).unwrap();
    match runner().run(&strategy, |_| Err(TestCaseError::fail("shrink this value"))) {
        Err(TestError::Fail(_, Ok(value))) => {
            assert!(matches!(schema.check_with_context(value, &ls::TypeRef::named("Bounded", vec![]),
                64, &mut ls::Context::default()).unwrap(), ls::ValueCheck::Accepted(_)));
        }
        result => panic!("expected a valid minimized counterexample: {result:?}"),
    }
}

#[test]
fn indexed_predicate_errors_reach_the_property() {
    let schema = schema(|_, _, _, _, _| Err("predicate evaluation failed".into()));
    runner().run(&draw(&schema), |value| {
        assert!(value.unwrap_err().contains("predicate evaluation failed"));
        Ok(())
    }).unwrap();
}
