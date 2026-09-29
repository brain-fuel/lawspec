use lawspec_example::domain::Wrapped;
use proptest::prelude::*;
use std::fmt::Debug;
use std::sync::atomic::{AtomicUsize, Ordering};

pub static WRAPPED_SAMPLES: AtomicUsize = AtomicUsize::new(0);

pub fn wrapped<T: Debug + 'static>(values: BoxedStrategy<T>) -> impl Strategy<Value = Wrapped<T>> {
    values.prop_map(|stored| {
        WRAPPED_SAMPLES.fetch_add(1, Ordering::SeqCst);
        Wrapped { stored }
    })
}

pub fn bytes() -> impl Strategy<Value = i8> {
    (5i8..20).prop_map(|value| {
        BYTE_SAMPLES.set(BYTE_SAMPLES.get() + 1);
        value
    })
}

thread_local! {
    static BYTE_SAMPLES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

pub fn reset_byte_samples() {
    BYTE_SAMPLES.set(0);
}
pub fn byte_samples() -> usize {
    BYTE_SAMPLES.get()
}

pub fn seals() -> BoxedStrategy<lawspec_example::domain::Seal> {
    panic!("a finite singleton must be enumerated, not sampled")
}
