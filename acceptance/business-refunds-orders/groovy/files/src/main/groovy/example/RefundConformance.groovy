package example
import lawspec.data.RefundRequest
import lawspec.data.RefundDecision
@groovy.transform.CompileStatic
final class RefundConformance {
  static RefundDecision nativeRefund(RefundRequest request) {
    if (request.requestedAmount().signum() == 0) return new RefundDecision.Approved()
    if (request.requestedAmount().compareTo(request.capturedAmount()) > 0) return new RefundDecision.Rejected()
    if (request.flagged()) return new RefundDecision.ReviewRequired()
    return new RefundDecision.Approved()
  }
}
