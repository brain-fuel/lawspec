// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (shop.orders::type::Currency -> shop.domain::type::Currency)
pub fn settlement(
    value0: crate::lawspec_data::ShopOrdersCurrency,
) -> crate::lawspec_data::ShopDomainCurrency {
    todo!("shop.orders::settlement")
}

// LawSpec: (shop.orders::type::Line -> shop.domain::type::Money)
pub fn lineTotal(value0: crate::lawspec_data::Line) -> crate::lawspec_data::Money {
    todo!("shop.orders::lineTotal")
}

// LawSpec: (Int64 -> (Int64 -> Int64))
pub fn cheaper(value0: i64, value1: i64) -> i64 {
    todo!("shop.orders::cheaper")
}

// LawSpec: (Int64 -> Int64)
pub fn roundDown(value0: i64) -> i64 {
    todo!("shop.orders::roundDown")
}

// LawSpec: (Int64 -> shop.tax.v2_0_0.rates::type::Band)
pub fn classify(value0: i64) -> crate::lawspec_data::ShopTaxV200RatesBand {
    todo!("shop.orders::classify")
}
