#[test]
fn native_price_strategy_is_used_and_keeps_its_shrinker() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    use proptest::test_runner::TestRunner;
    use std::sync::atomic::Ordering;
    let schema = lawspec_schema::schema()?;
    let ty = ls::TypeRef::named("example.payments::type::Money", vec![]);
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
            panic!("money");
        };
        let ls::Value::Decimal(amount) = &fields[0] else {
            panic!("decimal");
        };
        assert_eq!(amount.ratio()?, ls::BigRational::from_integer(1.into()));
        let ls::Value::Data(currency, _) = &fields[1] else {
            panic!("currency");
        };
        assert_eq!(currency, "example.payments::type::Currency::EUR");
    }
    assert!(shrunk);
    assert!(lawspec_generators::SAMPLES.load(Ordering::SeqCst) > 0);
    Ok(())
}
