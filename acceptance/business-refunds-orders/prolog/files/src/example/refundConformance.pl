/** <module> Refund policy implemented independently in Prolog.

The shared examples exercise zero, over-limit, flagged and large exact amounts.
*/
:- module(example_refund_conformance, [ls_nativeRefund/2]).

ls_nativeRefund(value('example.refunds::type::RefundRequest::RefundRequest',
                     [Captured, Requested, Flagged]),
                value(Decision, [])) :-
    ( Requested =:= 0 -> Decision='example.refunds::type::RefundDecision::Approved'
    ; Requested > Captured -> Decision='example.refunds::type::RefundDecision::Rejected'
    ; Flagged == true -> Decision='example.refunds::type::RefundDecision::ReviewRequired'
    ; Decision='example.refunds::type::RefundDecision::Approved'
    ).
