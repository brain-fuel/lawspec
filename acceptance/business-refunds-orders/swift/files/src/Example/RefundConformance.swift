import LawSpecRuntime
extension Example.RefundConformance {
    static func nativeRefund(_ request: RefundRequest) -> RefundDecision {
        if request.requestedAmount == 0 { return .approved }
        if request.requestedAmount > request.capturedAmount { return .rejected }
        if request.flagged { return .reviewRequired }
        return .approved
    }
}
