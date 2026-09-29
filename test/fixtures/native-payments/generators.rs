use lawspec_example::domain::{CurrencyCode, Price};
use lawspec_example::lawspec_runtime::Decimal;
use proptest::prelude::*;
use std::sync::atomic::{AtomicUsize, Ordering};

pub static SAMPLES: AtomicUsize = AtomicUsize::new(0);

// Deliberately excludes the explicit USD/GBP, tiny and large-value examples.
// Range shrinking must retain this strategy's lower bound of exactly one euro.
pub fn prices() -> impl Strategy<Value = Price> {
    (100i32..200).prop_map(|cents| {
        SAMPLES.fetch_add(1, Ordering::SeqCst);
        Price {
            major: Decimal::new(cents.into(), (-2).into()),
            unit: CurrencyCode::Euros,
        }
    })
}
