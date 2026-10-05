// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Int32 -> Bool)
pub fn charge(
    gateway: &dyn crate::lawspec_abilities::example_abilities::Gateway,
    value0: i32,
) -> bool {
    match gateway.authorize(value0) {
        crate::lawspec_data::Payment::Approved { cents } => gateway.capture(cents).cents == value0,
        crate::lawspec_data::Payment::Declined => false,
    }
}

/// The native handler of Gateway: authorize, capture, fee.
#[derive(Default)]
pub struct GatewayHandler;

impl crate::lawspec_abilities::example_abilities::Gateway for GatewayHandler {
    fn authorize(&self, value0: i32) -> crate::lawspec_data::Payment {
        if value0 < 0 {
            crate::lawspec_data::Payment::Declined
        } else {
            crate::lawspec_data::Payment::Approved { cents: value0 }
        }
    }

    fn capture(&self, value0: i32) -> crate::lawspec_data::Receipt {
        crate::lawspec_data::Receipt { cents: value0 }
    }

    fn fee(&self) -> i32 {
        25
    }
}
