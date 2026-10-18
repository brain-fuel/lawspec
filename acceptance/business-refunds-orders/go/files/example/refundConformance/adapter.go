package refundConformance

func NativeRefund(request RefundRequest) RefundDecision {
	if request.RequestedAmount.Sign() == 0 {
		return RefundDecisionApproved{}
	}
	if request.RequestedAmount.Cmp(request.CapturedAmount) > 0 {
		return RefundDecisionRejected{}
	}
	if request.Flagged {
		return RefundDecisionReviewRequired{}
	}
	return RefundDecisionApproved{}
}
