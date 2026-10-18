import * as data from '../lawspec_data.mjs';
export function nativeRefund(request) {
  if (request.requestedAmount === 0n) return new data.RefundDecisionApproved();
  if (request.requestedAmount > request.capturedAmount) return new data.RefundDecisionRejected();
  if (request.flagged) return new data.RefundDecisionReviewRequired();
  return new data.RefundDecisionApproved();
}
