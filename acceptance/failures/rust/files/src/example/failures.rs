// User-owned LawSpec adapter: the native Gateway handler.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

/// The native handler of Gateway: decide.
#[derive(Default)]
pub struct GatewayHandler;

impl crate::lawspec_abilities::example_failures::Gateway for GatewayHandler {
    fn decide(&self, value0: i32) -> crate::lawspec_data::Decision {
        if value0 < 0 {
            return crate::lawspec_data::Decision::Block;
        }
        if value0 % 2 == 1 {
            return crate::lawspec_data::Decision::Decline { reason: "an odd amount".into() };
        }
        crate::lawspec_data::Decision::Approve
    }
}

// Native adapters that fail: they fail with the runtime's ls::fail and a
// PaymentError, which a law expects with `fails with`.
pub fn refund(value0: i32) -> i32 {
    if value0 > 5000 {
        ls::fail(crate::lawspec_data::PaymentError::TooLarge { limit: 5000 });
    }
    value0
}

pub async fn settle(value0: i32) -> i32 {
    if value0 < 0 {
        ls::fail(crate::lawspec_data::PaymentError::Blocked);
    }
    if value0 == 0 {
        ls::fail(crate::lawspec_data::PaymentError::Declined { message: "there is nothing to settle".into() });
    }
    value0
}
