// User-owned LawSpec adapters for the matchers example.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (List (Int32) -> List (Int32))
pub fn sortItems(value0: Vec<i32>) -> Vec<i32> {
    let mut items = value0;
    items.sort();
    items
}

// LawSpec: (List (Text) -> List (Text))
pub fn uniqueTags(value0: Vec<String>) -> Vec<String> {
    let mut tags: Vec<String> = vec![];
    for tag in value0 {
        if !tags.contains(&tag) {
            tags.push(tag);
        }
    }
    tags
}

// LawSpec: (Int32 -> (Int32 -> Float64))
pub fn average(value0: i32, value1: i32) -> f64 {
    (value0 as f64 + value1 as f64) / 2.0
}

// LawSpec: (Text -> Text)
pub fn slug(value0: String) -> String {
    let lower = value0.to_lowercase();
    let words: Vec<&str> = lower
        .split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit()))
        .filter(|w| !w.is_empty())
        .collect();
    words.join("-")
}

// LawSpec: (Int32 -> example.matchers::type::Order)
pub fn ship(value0: i32) -> crate::lawspec_data::Order {
    crate::lawspec_data::Order::Shipped { id: value0, carrier: "post".into() }
}
