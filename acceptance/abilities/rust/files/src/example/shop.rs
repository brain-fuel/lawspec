// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through ls::fail.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Int32 -> Int32)
pub fn refund(
    gateway: &dyn crate::lawspec_abilities::example_abilities::Gateway,
    value0: i32,
) -> i32 {
    if value0 > 100000 {
        ls::fail(crate::lawspec_data::PaymentError::TooLarge);
    }
    gateway.capture(value0).cents
}

/// The native handler of Log: note.
#[derive(Default)]
pub struct LogHandler {
    lines: std::sync::Mutex<Vec<String>>,
}

impl crate::lawspec_abilities::example_shop::Log for LogHandler {
    fn note(&self, value0: std::string::String) -> () {
        self.lines.lock().unwrap().push(value0);
    }
}

/// The native handler of Store Int32: load, save.
#[derive(Default)]
pub struct StoreInt32Handler {
    value: std::sync::Mutex<i32>,
}

impl crate::lawspec_abilities::example_shop::StoreInt32 for StoreInt32Handler {
    fn load(&self) -> i32 {
        *self.value.lock().unwrap()
    }

    fn save(&self, value0: i32) -> () {
        *self.value.lock().unwrap() = value0;
    }
}

/// The native handler of Store Text: load, save.
#[derive(Default)]
pub struct StoreTextHandler {
    value: std::sync::Mutex<String>,
}

impl crate::lawspec_abilities::example_shop::StoreText for StoreTextHandler {
    fn load(&self) -> std::string::String {
        self.value.lock().unwrap().clone()
    }

    fn save(&self, value0: std::string::String) -> () {
        *self.value.lock().unwrap() = value0;
    }
}

/// The native handler of Meter: reading.
#[derive(Default)]
pub struct MeterHandler;

impl crate::lawspec_abilities::example_shop::Meter for MeterHandler {
    fn reading(&self) -> i32 {
        3
    }
}
