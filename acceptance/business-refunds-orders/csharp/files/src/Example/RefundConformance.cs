namespace Example;
using LawSpec.Data;
public static class RefundConformance {
    public static RefundDecision NativeRefund(RefundRequest request) {
        if (request.RequestedAmount.IsZero) return RefundDecision.Approved;
        if (request.RequestedAmount > request.CapturedAmount) return RefundDecision.Rejected;
        if (request.Flagged) return RefundDecision.ReviewRequired;
        return RefundDecision.Approved;
    }
}
