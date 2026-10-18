package example
import lawspec.data.{RefundRequest, RefundDecision}
object RefundConformance {
  def nativeRefund(request: RefundRequest): RefundDecision = {
    if (request.requestedAmount == 0) RefundDecision.Approved
    else if (request.requestedAmount > request.capturedAmount) RefundDecision.Rejected
    else if (request.flagged) RefundDecision.ReviewRequired
    else RefundDecision.Approved
  }
}
