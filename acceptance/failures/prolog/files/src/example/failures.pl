/** <module> Synchronous and asynchronous adapters with declared failures.
ref:DEC-prolog-janus
*/
:- module(lawspec_e7de6d7eaf2b839c,
          [ls_refund/2, ls_settle/2, handler_GatewayHandler_new/1,
           handler_GatewayHandler_decide/3]).

handler_GatewayHandler_new(gateway).
handler_GatewayHandler_decide(gateway, Amount, Decision) :-
    ( Amount < 0 -> Decision = value('example.failures::type::Decision::Block', [])
    ; Amount mod 2 =:= 1 -> Decision = value('example.failures::type::Decision::Decline', ["an odd amount"])
    ; Decision = value('example.failures::type::Decision::Approve', [])
    ).

ls_refund(Amount, R) :-
    ( Amount > 5000 -> throw(lawspec_failure(value('example.failures::type::PaymentError::TooLarge', [5000])))
    ; R = Amount
    ).

ls_settle(Amount, R) :-
    ( Amount < 0 -> throw(lawspec_failure(value('example.failures::type::PaymentError::Blocked', [])))
    ; Amount =:= 0 -> throw(lawspec_failure(value('example.failures::type::PaymentError::Declined',
         [value('lawspec::structural::record::f5f10555f6c6efcfede6a1b5b3a543dda5cd98cceb0297c257aa71c41066c7c7::Record', ["there is nothing to settle"])])))
    ; R = Amount
    ).
