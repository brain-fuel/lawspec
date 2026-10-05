// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]
use crate::lawspec_data::{Line, Money, Quantity, ShopDomainCurrency, ShopOrdersCurrency, ShopTaxV200RatesBand};

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

// Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
pub fn classify(value0: i64) -> ShopTaxV200RatesBand {
    if value0 <= 0 {
        ShopTaxV200RatesBand::Zero
    } else if value0 < 10000 {
        ShopTaxV200RatesBand::Low
    } else {
        ShopTaxV200RatesBand::High
    }
}
