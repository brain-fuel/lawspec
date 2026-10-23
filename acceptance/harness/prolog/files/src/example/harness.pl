/** <module> Native discount, expected failure and handler recording controls.
ref:DEC-prolog-janus
*/
:- module(example_harness,
          [ls_discount/2, ls_roundCents/2, ls_book/3,
           handler_LedgerHandler_new/1, handler_LedgerHandler_accept/3]).

ls_discount(value(_, [Items, Total]), R) :-
    ( Items > 10 -> R is Total div 10 ; R = 0 ).
ls_roundCents(Cents, R) :- R is (Cents+4) div 10*10.
ls_book(Ledger, Cents, R) :- lawspec_prolog:operation(Ledger, accept, [Cents], R).

handler_LedgerHandler_new(ledger).
handler_LedgerHandler_accept(ledger, Cents, R) :- ( Cents > 0 -> R = true ; R = false ).
