use lawspec_example::domain::{CurrencyCode, Price};
use lawspec_example::lawspec_runtime::Decimal;
use proptest::prelude::*;

// The native range strategy retains its shrinker through this mapping.
pub fn prices() -> impl Strategy<Value = Price> {
    (100i32..=200).prop_map(|cents| Price {
        major: Decimal::new(cents.into(), (-2).into()),
        unit: CurrencyCode::Euros,
    })
}
