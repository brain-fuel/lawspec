package example
import lawspec.data.RefundRequest
import lawspec.data.RefundDecision
object RefundConformance {
    fun nativeRefund(request: RefundRequest): RefundDecision {
        if (request.requestedAmount.signum() == 0) return RefundDecision.Approved
        if (request.requestedAmount > request.capturedAmount) return RefundDecision.Rejected
        if (request.flagged) return RefundDecision.ReviewRequired
        return RefundDecision.Approved
    }
}
