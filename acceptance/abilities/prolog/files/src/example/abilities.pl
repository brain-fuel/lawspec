/** <module> Native capabilities and calls through explicit handler arguments.
ref:DEC-prolog-janus
*/
:- module(lawspec_af323b38be780e60,
          [ls_charge/3, handler_GatewayHandler_new/1,
           handler_GatewayHandler_authorize/3, handler_GatewayHandler_capture/3,
           handler_GatewayHandler_fee/2]).

handler_GatewayHandler_new(gateway).
handler_GatewayHandler_authorize(gateway, Amount, R) :-
    ( Amount < 0 -> R = value('example.abilities::type::Payment::Declined', [])
    ; R = value('example.abilities::type::Payment::Approved', [Amount])
    ).
handler_GatewayHandler_capture(gateway, Amount,
    value('example.abilities::type::Receipt::Receipt', [Amount])).
handler_GatewayHandler_fee(gateway, 25).

ls_charge(Gateway, Amount, R) :-
    lawspec_prolog:operation(Gateway, authorize, [Amount], Payment),
    ( Payment = value('example.abilities::type::Payment::Approved', [Approved]) ->
        lawspec_prolog:operation(Gateway, capture, [Approved], value(_, [Paid])),
        ( Paid =:= Amount -> R = true ; R = false )
    ; R = false
    ).
