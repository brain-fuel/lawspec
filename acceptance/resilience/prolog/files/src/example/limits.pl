/** <module> Native steps for limits, compensation, timeout and hedging.
ref:DEC-prolog-janus
*/
:- module(example_limits, [ls_admitTicket/2, ls_reserveSeat/2,
    ls_chargeCard/2, ls_releaseSeat/2, ls_fetchQuote/2, ls_hedgeQuote/2,
    reset_quotes/0]).

ls_admitTicket(Ticket, value('Either::Right', [Ticket])).
ls_reserveSeat(Ticket, value('Either::Right', [Ticket])).
ls_chargeCard(Ticket, Result) :-
    Ticket = value(_, [Number]),
    ( Number < 0 -> Result = value('Either::Left', ["declined"])
    ; Result = value('Either::Right', [Ticket])
    ).
ls_releaseSeat(_, true).
ls_fetchQuote(Ticket, value('Either::Right', [Ticket])) :-
    Ticket = value(_, [Number]),
    ( Number =:= -1 -> sleep(0.6) ; true ).
ls_hedgeQuote(Ticket, value('Either::Right', [Ticket])) :-
    Ticket = value(_, [Number]),
    ( Number =:= -2 ->
        flag(lawspec_fixture_quotes, Previous, Previous+1),
        ( Previous mod 2 =:= 0 -> sleep(0.6) ; true )
    ; true
    ).
reset_quotes :- flag(lawspec_fixture_quotes, _, 0).
