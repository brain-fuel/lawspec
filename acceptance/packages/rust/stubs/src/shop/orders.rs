// Scaffolded by LawSpec from orders.lawspec. User-owned; never overwritten.

// settlement — orders.lawspec:13
// LawSpec type: shop.orders::type::Currency -> shop.domain::type::Currency
pub fn settlement(
    value0: crate::lawspec_data::ShopOrdersCurrency,
) -> crate::lawspec_data::ShopDomainCurrency {
    todo!("shop.orders::settlement")
}

// lineTotal — orders.lawspec:14
// LawSpec type: shop.orders::type::Line -> shop.domain::type::Money
#[allow(non_snake_case)]
pub fn lineTotal(value0: crate::lawspec_data::Line) -> crate::lawspec_data::Money {
    todo!("shop.orders::lineTotal")
}

// cheaper — orders.lawspec:17
// LawSpec type: Int64 -> (Int64 -> Int64)
pub fn cheaper(value0: i64, value1: i64) -> i64 {
    todo!("shop.orders::cheaper")
}

// roundDown — orders.lawspec:18
// LawSpec type: Int64 -> Int64
#[allow(non_snake_case)]
pub fn roundDown(value0: i64) -> i64 {
    todo!("shop.orders::roundDown")
}

// classify — orders.lawspec:19
// LawSpec type: Int64 -> shop.tax.v2x0x0.rates::type::Band
pub fn classify(value0: i64) -> crate::lawspec_data::ShopTaxV2x0x0RatesBand {
    todo!("shop.orders::classify")
}
