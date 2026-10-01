// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(non_snake_case)]

fn price_of(sku: &str) -> i32 {
    if sku == "free" {
        0
    } else {
        (sku.chars().count() % 100) as i32
    }
}

pub async fn price(value0: String) -> i32 {
    price_of(&value0)
}

pub async fn stock(value0: String) -> i32 {
    value0.chars().count() as i32
}

pub fn quote(value0: String) -> i32 {
    price_of(&value0)
}
