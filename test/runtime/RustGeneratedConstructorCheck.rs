mod lawspec_data;
mod lawspec_definitions;
mod lawspec_runtime;
mod lawspec_schema;

use lawspec_data::*;
use lawspec_definitions::native_fields as native;
use lawspec_runtime as ls;

fn rejected<T>(result: ls::Result<T>) {
    match result {
        Err(message) => {
            assert!(message.contains("field refinement"), "{message}");
            assert!(!message.contains("division by zero"), "{message}");
        }
        Ok(_) => panic!("invalid constructor accepted"),
    }
}

fn main() -> ls::Result<()> {
    let ctx = &mut ls::Context::default();
    assert_eq!(
        native::inverseGap(
            ctx,
            Gap::Gap {
                first: -128,
                second: 127
            }
        )?,
        ls::BigRational::new(1.into(), 255.into()),
    );
    rejected(native::inverseGap(
        ctx,
        Gap::Gap {
            first: 0,
            second: 0,
        },
    ));
    rejected(native::inverseGap(
        ctx,
        Gap::Gap {
            first: 127,
            second: -128,
        },
    ));
    assert!(matches!(
        native::echoBucket(ctx, Bucket::Bucket { values: vec![1] })?,
        Bucket::Bucket { values } if values == vec![1]
    ));
    rejected(native::echoBucket(ctx, Bucket::Bucket { values: vec![] }));
    native::echoPositives(ctx, Positives::Positives { values: vec![1, 2] })?;
    rejected(native::echoPositives(
        ctx,
        Positives::Positives { values: vec![0] },
    ));
    native::echoChoice(
        ctx,
        Choice::Rejected {
            reason: "no".into(),
        },
    )?;
    native::echoChoice(ctx, Choice::Accepted { value: 1 })?;
    rejected(native::echoChoice(ctx, Choice::Accepted { value: 0 }));
    native::echoGuarded(ctx, Guarded::Guarded { value: 2 })?;
    rejected(native::echoGuarded(ctx, Guarded::Guarded { value: 0 }));
    rejected(native::echoGuarded(ctx, Guarded::Guarded { value: -1 }));
    let bits: u32 = std::env::var("MACHINE_BITS").unwrap().parse().unwrap();
    if bits == usize::BITS {
        native::echoMachine(ctx, Machine::Machine { value: 1 })?;
        rejected(native::echoMachine(ctx, Machine::Machine { value: 0 }));
    } else {
        assert!(
            native::echoMachine(ctx, Machine::Machine { value: 1 })
                .unwrap_err()
                .contains("machineBits does not match")
        );
    }
    let symbol = ctx.symbol("fixture", "same");
    assert!(matches!(
        native::echoIdentity(ctx, Identity::Identity { value: symbol.clone() })?,
        Identity::Identity { value } if value == symbol
    ));
    rejected(native::echoIdentity(
        &mut ls::Context::default(),
        Identity::Identity { value: symbol },
    ));
    let wrong = ls::Context::default().symbol("fixture", "same");
    rejected(native::echoIdentity(
        ctx,
        Identity::Identity { value: wrong },
    ));
    native::echoSame(
        ctx,
        Same::Same {
            first: 1.0,
            second: 1.0,
        },
    )?;
    rejected(native::echoSame(
        ctx,
        Same::Same {
            first: 1.0,
            second: 2.0,
        },
    ));

    let schema = lawspec_schema::schema()?;
    let ty = ls::TypeRef::named("native.fields::type::Same", vec![]);
    let pair = |a, b| {
        ls::Value::Data(
            "native.fields::type::Same::Same".into(),
            vec![ls::Value::Float64(a), ls::Value::Float64(b)],
        )
    };
    schema.validate_with_context(pair(0.0, -0.0), &ty, bits, ctx)?;
    rejected(schema.validate_with_context(pair(f64::NAN, f64::NAN), &ty, bits, ctx));
    let key = ls::TypeRef::named("List", vec![ls::TypeRef::Parameter(0)])
        .instantiate(&[ls::TypeRef::named("Bool", vec![])])?
        .expression_key()?;
    assert_eq!(key, "List Bool");
    assert!(ls::TypeRef::Parameter(0).expression_key().is_err());
    assert!(ls::TypeRef::Parameter(0).instantiate(&[]).is_err());
    Ok(())
}
