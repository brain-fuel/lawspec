import * as data from '../lawspec_data.js';
export function nativeRefund(request: data.RefundRequest): data.RefundDecision {
  if (request.requestedAmount === 0n) return new data.RefundDecisionApproved();
  if (request.requestedAmount > request.capturedAmount) return new data.RefundDecisionRejected();
  if (request.flagged) return new data.RefundDecisionReviewRequired();
  return new data.RefundDecisionApproved();
}
