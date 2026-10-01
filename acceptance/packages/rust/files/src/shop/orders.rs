// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{Line, Money, Quantity, ShopDomainCurrency, ShopOrdersCurrency};

pub fn settlement(value0: ShopOrdersCurrency) -> ShopDomainCurrency {
    match value0 {
        ShopOrdersCurrency::Usd => ShopDomainCurrency::Usd,
        ShopOrdersCurrency::Gbp => ShopDomainCurrency::Eur,
    }
}

pub fn lineTotal(value0: Line) -> Money {
    let Line { price, quantity } = value0;
    let Money { currency, cents } = price;
    let Quantity { value: count } = quantity;
    Money { currency, cents: (cents * i64::from(count)).min(100000000) }
}

pub fn cheaper(value0: i64, value1: i64) -> i64 {
    value0.min(value1)
}

pub fn roundDown(value0: i64) -> i64 {
    value0 - value0 % 100
}
