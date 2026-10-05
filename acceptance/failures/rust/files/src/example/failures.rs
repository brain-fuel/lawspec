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
