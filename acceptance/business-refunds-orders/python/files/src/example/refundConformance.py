import lawspec_data as data

def nativeRefund(request: data.RefundRequest) -> data.RefundDecision:
    if request.requestedAmount == 0:
        return data.RefundDecisionApproved()
    if request.requestedAmount > request.capturedAmount:
        return data.RefundDecisionRejected()
    if request.flagged:
        return data.RefundDecisionReviewRequired()
    return data.RefundDecisionApproved()
