#[test]
fn generic_native_factory_keeps_child_shrinking() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    use proptest::test_runner::TestRunner;
    use std::sync::atomic::Ordering;
    let schema = lawspec_schema::schema()?;
    let ty = ls::TypeRef::named(
        "native.shapes::type::Box",
        vec![ls::TypeRef::named("Int8", vec![])],
    );
    let strategy = ls_gen::schema_strategy_with_generators(
        &schema,
        &ty,
        64,
        64,
        &ls::Context::default(),
        &_lawspec_native_generators()?,
    )?;
    let mut runner = TestRunner::deterministic();
    let mut shrunk = false;
    for _ in 0..20 {
        let mut tree = strategy.new_tree(&mut runner).unwrap();
        while tree.simplify() {
            shrunk = true;
        }
        let ls::Value::Data(_, fields) = tree.current() else {
            panic!("box");
        };
        assert_eq!(fields, vec![ls::Value::Integer(5.into())]);
    }
    assert!(shrunk);
    assert!(lawspec_generators::WRAPPED_SAMPLES.load(Ordering::SeqCst) > 0);
    Ok(())
}

#[test]
fn refined_quantifiers_do_not_replace_custom_generators_with_bounded_defaults() -> ls::Result<()> {
    lawspec_generators::reset_byte_samples();
    test_5()?;
    assert!(lawspec_generators::byte_samples() > 0);
    Ok(())
}

#[test]
fn finite_domains_remain_exhaustive_with_custom_generator_bindings() -> ls::Result<()> {
    test_4()
}
