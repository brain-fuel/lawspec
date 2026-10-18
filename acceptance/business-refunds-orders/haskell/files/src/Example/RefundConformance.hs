module Example.RefundConformance where
import qualified LawSpecData as Data

nativeRefund :: Data.RefundRequest -> Data.RefundDecision
nativeRefund (Data.RefundRequest captured requested flagged)
  | requested == 0 = Data.RefundDecisionApproved
  | requested > captured = Data.RefundDecisionRejected
  | flagged = Data.RefundDecisionReviewRequired
  | otherwise = Data.RefundDecisionApproved
