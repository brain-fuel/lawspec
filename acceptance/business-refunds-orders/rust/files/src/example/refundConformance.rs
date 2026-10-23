#![allow(non_snake_case)]
use crate::lawspec_data::{RefundDecision, RefundRequest};
use crate::lawspec_runtime::BigUint;

pub fn nativeRefund(request: RefundRequest) -> RefundDecision {
    if request.requestedAmount == BigUint::from(0u8) {
        return RefundDecision::Approved;
    }
    if request.requestedAmount > request.capturedAmount {
        return RefundDecision::Rejected;
    }
    if request.flagged {
        return RefundDecision::ReviewRequired;
    }
    RefundDecision::Approved
}
