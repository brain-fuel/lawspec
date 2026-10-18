module Example.RefundConformance
open LawSpec.Data

let nativeRefund (request: RefundRequest) : RefundDecision =
    if request.RequestedAmount = 0I then RefundDecision.Approved
    elif request.RequestedAmount > request.CapturedAmount then RefundDecision.Rejected
    elif request.Flagged then RefundDecision.ReviewRequired
    else RefundDecision.Approved
