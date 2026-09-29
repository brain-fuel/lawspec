#[test]
fn codec_hooks_preserve_generic_native_shrinking() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    use proptest::test_runner::TestRunner;
    let schema = lawspec_schema::schema()?;
    let ty = ls::TypeRef::named(
        "native.codecs::type::Parcel",
        vec![ls::TypeRef::named("Int8", vec![])],
    );
    let strategy = ls_gen::checked_schema_strategy_with_generators(
        &schema,
        &ty,
        64,
        64,
        &ls::Context::default(),
        vec![],
        &_lawspec_native_generators()?,
    )?;
    let mut runner = TestRunner::deterministic();
    let mut shrunk = false;
    for _ in 0..20 {
        let mut tree = strategy.new_tree(&mut runner).unwrap();
        while tree.simplify() {
            shrunk = true;
        }
        let ls::Value::Data(_, fields) = tree.current()? else {
            panic!("expected Parcel");
        };
        assert_eq!(fields, vec![ls::Value::Integer(0.into())]);
    }
    assert!(shrunk);
    Ok(())
}
