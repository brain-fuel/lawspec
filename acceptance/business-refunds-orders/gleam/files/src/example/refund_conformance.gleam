import lawspec/data

pub fn native_refund(request: data.RefundRequest) -> data.RefundDecision {
  case request.requested_amount == 0, request.requested_amount > request.captured_amount, request.flagged {
    True, _, _ -> data.RefundDecisionApproved
    _, True, _ -> data.RefundDecisionRejected
    _, _, True -> data.RefundDecisionReviewRequired
    _, _, _ -> data.RefundDecisionApproved
  }
}
