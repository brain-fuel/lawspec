#[test]
fn native_data_rejects_foreign_tags_and_wrong_arity() {
    use ls::FromValue;
    for value in [
        ls::Value::Bool(true),
        ls::Value::Data("foreign::Leaf".into(), vec![ls::Value::Integer(1.into())]),
        ls::Value::Data("example.data_types::type::Tree::Leaf".into(), vec![]),
    ] {
        assert!(lawspec_data::Tree::<i8>::from_value(value).is_err());
    }
}

#[test]
fn native_data_preserves_ieee_and_symbol_identity() -> ls::Result<()> {
    use ls::IntoValue;
    let nan = lawspec_data::Tree::Leaf { value: f64::NAN }.into_value();
    assert!(!ls::equal(&nan, &nan)?);
    let negative = lawspec_data::Tree::Leaf { value: -0.0_f64 }.into_value();
    let positive = lawspec_data::Tree::Leaf { value: 0.0_f64 }.into_value();
    assert!(ls::equal(&negative, &positive)?);
    let mut context = ls::Context::default();
    let first = context.symbol("first", "same");
    let same = context.symbol("first", "same");
    let different = context.symbol("second", "same");
    let leaf = |value| lawspec_data::Tree::Leaf { value }.into_value();
    assert!(ls::equal(&leaf(first.clone()), &leaf(same))?);
    assert!(!ls::equal(&leaf(first), &leaf(different))?);
    Ok(())
}

#[test]
fn native_schema_shrinking_keeps_valid_recursive_values() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    let schema = lawspec_schema::schema()?;
    let ty = ls::TypeRef::named(
        "example.data_types::type::Tree",
        vec![ls::TypeRef::named("Int8", vec![])],
    );
    let strategy = ls_gen::schema_strategy(&schema, &ty, 64, 32)?;
    let mut runner = proptest::test_runner::TestRunner::deterministic();
    let mut shrinks = 0;
    for _ in 0..64 {
        let mut tree = strategy.new_tree(&mut runner).map_err(|e| e.to_string())?;
        schema.validate(tree.current(), &ty, 64)?;
        assert!(structural_nodes(&tree.current()) <= 32);
        for _ in 0..256 {
            if !tree.simplify() {
                break;
            }
            shrinks += 1;
            schema.validate(tree.current(), &ty, 64)?;
            assert!(structural_nodes(&tree.current()) <= 32);
        }
        if tree.complicate() {
            schema.validate(tree.current(), &ty, 64)?;
        }
    }
    assert!(
        shrinks > 0,
        "recursive strategies must retain native shrinking"
    );
    Ok(())
}

fn structural_nodes(value: &ls::Value) -> usize {
    match value {
        ls::Value::Data(_, fields) | ls::Value::List(fields) => {
            1 + fields.iter().map(structural_nodes).sum::<usize>()
        }
        ls::Value::Maybe(value) | ls::Value::Nullable(value) | ls::Value::Optional(value) => {
            1 + value.as_ref().map_or(0, |value| structural_nodes(value))
        }
        ls::Value::Left(value) | ls::Value::Right(value) => 1 + structural_nodes(value),
        _ => 1,
    }
}

#[test]
fn schema_budget_reserves_uneven_field_minima() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    let names = ["Deep0", "Deep1", "Deep2", "Deep3", "Deep4", "Deep5"];
    let mut definitions = Vec::new();
    for (index, name) in names.iter().enumerate() {
        definitions.push(ls::DataSchema {
            name,
            parameters: 0,
            constructors: vec![ls::ConstructorSchema {
                tag: name,
                fields: if index == 0 {
                    vec![]
                } else {
                    vec![ls::TypeRef::named(names[index - 1], vec![])]
                },
            }],
        });
    }
    let mut fields = vec![ls::TypeRef::named("Deep5", vec![])];
    fields.extend((0..9).map(|_| ls::TypeRef::named("Bool", vec![])));
    definitions.push(ls::DataSchema {
        name: "Uneven",
        parameters: 0,
        constructors: vec![ls::ConstructorSchema {
            tag: "Uneven::Make",
            fields,
        }],
    });
    let schema = ls::Schema::new(definitions)?;
    let ty = ls::TypeRef::named("Uneven", vec![]);
    assert!(ls_gen::schema_strategy(&schema, &ty, 64, 15).is_err());
    let strategy = ls_gen::schema_strategy(&schema, &ty, 64, 16)?;
    let mut runner = proptest::test_runner::TestRunner::deterministic();
    for _ in 0..64 {
        let mut tree = strategy.new_tree(&mut runner).map_err(|e| e.to_string())?;
        loop {
            let value = schema.validate(tree.current(), &ty, 64)?;
            assert_eq!(structural_nodes(&value), 16);
            if !tree.simplify() {
                break;
            }
        }
    }

    // A singleton has enough budget for the deep element. Dividing the element
    // budget by a fixed maximum length used to exclude every nonempty list.
    let list = ls::TypeRef::named("List", vec![ls::TypeRef::named("Deep5", vec![])]);
    let strategy = ls_gen::schema_strategy(&schema, &list, 64, 7)?;
    let mut nonempty = false;
    for _ in 0..64 {
        let value = strategy
            .new_tree(&mut runner)
            .map_err(|e| e.to_string())?
            .current();
        schema.validate(value.clone(), &list, 64)?;
        assert!(structural_nodes(&value) <= 7);
        nonempty |= matches!(value, ls::Value::List(items) if items.len() == 1);
    }
    assert!(nonempty, "valid deep elements must remain generatable");
    Ok(())
}

#[test]
fn schema_lists_grow_and_shrink_within_the_node_budget() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    let schema = ls::Schema::new(vec![])?;
    let ty = ls::TypeRef::named("List", vec![ls::TypeRef::named("Unit", vec![])]);
    assert!(ls_gen::schema_strategy(&schema, &ty, 64, 0).is_err());
    let strategy = ls_gen::schema_strategy(&schema, &ty, 64, 10)?;
    let mut runner = proptest::test_runner::TestRunner::deterministic();
    let mut longest = 0;
    let mut shrinks = 0;
    for _ in 0..64 {
        let mut tree = strategy.new_tree(&mut runner).map_err(|e| e.to_string())?;
        loop {
            let value = schema.validate(tree.current(), &ty, 64)?;
            assert!(structural_nodes(&value) <= 10);
            let ls::Value::List(items) = value else {
                panic!("expected List")
            };
            longest = longest.max(items.len());
            if !tree.simplify() {
                break;
            }
            shrinks += 1;
        }
    }
    assert!(
        longest > 4,
        "list generation must not have a hidden four-element cap"
    );
    assert!(shrinks > 0, "length shrinking must remain native");
    Ok(())
}

#[test]
fn schema_budget_counts_absence_and_sum_nodes() -> ls::Result<()> {
    use proptest::strategy::ValueTree;
    let schema = ls::Schema::new(vec![ls::DataSchema {
        name: "Empty",
        parameters: 0,
        constructors: vec![],
    }])?;
    let unit = ls::TypeRef::named("Unit", vec![]);
    let empty = ls::TypeRef::named("Empty", vec![]);
    assert!(ls_gen::schema_strategy(&schema, &empty, 64, 16).is_err());
    assert!(ls_gen::schema_strategy(&schema, &unit, 64, 0).is_err());
    let mut runner = proptest::test_runner::TestRunner::deterministic();
    for name in ["Maybe", "Nullable", "Optional"] {
        let ty = ls::TypeRef::named(name, vec![empty.clone()]);
        assert!(ls_gen::schema_strategy(&schema, &ty, 64, 0).is_err());
        let strategy = ls_gen::schema_strategy(&schema, &ty, 64, 1)?;
        let value = strategy
            .new_tree(&mut runner)
            .map_err(|e| e.to_string())?
            .current();
        schema.validate(value.clone(), &ty, 64)?;
        assert_eq!(structural_nodes(&value), 1);
    }
    let either = ls::TypeRef::named("Either", vec![empty, unit]);
    assert!(ls_gen::schema_strategy(&schema, &either, 64, 1).is_err());
    let strategy = ls_gen::schema_strategy(&schema, &either, 64, 2)?;
    let value = strategy
        .new_tree(&mut runner)
        .map_err(|e| e.to_string())?
        .current();
    schema.validate(value.clone(), &either, 64)?;
    assert_eq!(structural_nodes(&value), 2);
    assert!(matches!(value, ls::Value::Right(_)));
    Ok(())
}
