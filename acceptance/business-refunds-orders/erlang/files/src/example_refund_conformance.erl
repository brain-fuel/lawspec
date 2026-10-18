-module(example_refund_conformance).
-export([native_refund/1]).

native_refund({refund_request, Captured, Requested, Flagged}) ->
    case Requested of
        0 -> refund_decision_approved;
        _ when Requested > Captured -> refund_decision_rejected;
        _ when Flagged -> refund_decision_review_required;
        _ -> refund_decision_approved
    end.
