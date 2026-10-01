// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{Money, ShopDomainCurrency};

// One-to-one rates keep the example exact.
pub fn convert(value0: ShopDomainCurrency, value1: Money) -> Money {
    let Money { cents, .. } = value1;
    Money { currency: value0, cents }
}
