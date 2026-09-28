use crate::lawspec_data::{Architecture, Tree};
use crate::lawspec_definitions::{example_total as total, other};
use crate::lawspec_runtime as ls;

#[test]
fn native_definitions_are_reusable_without_property_frameworks() -> ls::Result<()> {
    let ctx = &mut ls::Context::default();
    assert_eq!(total::size(ctx, vec![1, 2, 3])?, ls::BigInt::from(3));
    assert_eq!(total::forward(ctx, vec![])?, ls::BigInt::from(0));
    assert_eq!(total::sumList(ctx, vec![127, 127])?, ls::BigInt::from(254));
    assert_eq!(total::increment(ctx, 127)?, ls::BigInt::from(128));
    assert!(!total::divisible(
        ctx,
        ls::BigInt::from(1),
        ls::BigInt::from(0)
    )?);
    assert!(total::divisible(
        ctx,
        ls::BigInt::from(-6),
        ls::BigInt::from(3)
    )?);
    assert_eq!(total::maybeDefault(ctx, None)?, 0);
    assert_eq!(total::maybeDefault(ctx, Some(127))?, 127);
    assert_eq!(
        total::raw(ctx, vec![0xd800, 0, 0xffff])?,
        vec![0xd800, 0, 0xffff]
    );
    let tree = Tree::Branch {
        left: Box::new(Tree::Leaf { value: 127 }),
        right: Box::new(Tree::Leaf { value: 127 }),
    };
    assert_eq!(total::sumTree(ctx, tree)?, ls::BigInt::from(254));
    assert!(!other::size(ctx, false)?);
    assert!(other::size(ctx, true)?);
    let states = [
        ls::Optional::Undefined,
        ls::Optional::Present(ls::Nullable::Null),
        ls::Optional::Present(ls::Nullable::Present(0)),
    ];
    for state in states {
        assert_eq!(total::absent(ctx, state.clone())?, state);
    }
    assert_eq!(total::symbol(ctx, ())?, total::symbol(ctx, ())?);
    assert_eq!(
        total::exact(ctx, ls::Decimal::new(1.into(), (-1).into()))?,
        ls::Decimal::new(3.into(), (-1).into()),
    );
    assert_eq!(
        total::either(ctx, ls::Either::Left(127))?,
        ls::Either::Left(127)
    );
    assert_eq!(
        total::either(ctx, ls::Either::Right(true))?,
        ls::Either::Right(true)
    );
    if MACHINE_COMPATIBLE {
        assert_eq!(total::machine(ctx, 42)?, 42);
        assert!(matches!(
            total::architecture(ctx, Architecture::Unused)?,
            Architecture::Unused
        ));
    } else {
        assert!(
            total::machine(ctx, 42)
                .unwrap_err()
                .contains("machineBits does not match")
        );
        assert!(
            total::architecture(ctx, Architecture::Unused)
                .unwrap_err()
                .contains("machineBits does not match")
        );
    }
    Ok(())
}

#[test]
fn internal_calls_check_arity_and_domains() {
    let ctx = &mut ls::Context::default();
    assert!(crate::lawspec_definitions::evaluate_0(ctx, vec![]).is_err());
    assert!(crate::lawspec_definitions::evaluate_0(ctx, vec![ls::Value::Bool(true)]).is_err());
    assert!(
        crate::lawspec_definitions::evaluate_0(
            ctx,
            vec![ls::Value::List(vec![ls::Value::Integer(128.into())])],
        )
        .is_err()
    );
}
