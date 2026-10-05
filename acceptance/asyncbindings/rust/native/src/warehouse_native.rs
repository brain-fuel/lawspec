//! Application code the warehouse adapters are bound to: some of it
//! asynchronous, as a real service client would be.

use std::sync::Mutex;

fn price(sku: &str) -> i32 {
    if sku == "free" {
        0
    } else {
        (sku.chars().count() % 100) as i32
    }
}

pub async fn price_of(sku: String) -> i32 {
    std::future::ready(()).await;
    price(&sku)
}

pub fn quote_of(sku: String) -> i32 {
    price(&sku)
}

/// A stock count that several callers may change.
#[derive(Debug, Default)]
pub struct Shelf {
    total: Mutex<i64>,
}

impl Shelf {
    pub fn new() -> Shelf {
        Shelf::default()
    }

    pub async fn restock(&self, amount: i32) {
        std::future::ready(()).await;
        *self.total.lock().unwrap() += amount as i64;
    }

    pub async fn count(&self) -> i64 {
        std::future::ready(()).await;
        *self.total.lock().unwrap()
    }
}
