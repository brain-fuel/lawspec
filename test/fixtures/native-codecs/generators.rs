use lawspec_example::domain;
use proptest::prelude::*;

pub fn parcels<T: std::fmt::Debug + 'static>(
    child: proptest::strategy::BoxedStrategy<T>,
) -> impl Strategy<Value = domain::Parcel<T>> {
    child.prop_map(domain::Parcel::new)
}

pub fn positives() -> impl Strategy<Value = domain::Positive> {
    (1i8..100).prop_map(domain::Positive::new)
}
