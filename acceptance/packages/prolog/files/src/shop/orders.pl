/** <module> Native order rules with distinct imported package versions.
ref:DEC-prolog-janus
*/
:- module(lawspec_7458f44cdbf1d509,
          [ls_settlement/2, ls_lineTotal/2, ls_cheaper/3, ls_roundDown/2, ls_classify/2]).

ls_settlement(value(Tag, []), R) :-
    ( Tag == 'shop.orders::type::Currency::Usd' -> R = value('shop.domain::type::Currency::Usd', [])
    ; R = value('shop.domain::type::Currency::Eur', [])
    ).

ls_lineTotal(value(_, [value(Tag, [Currency, Cents]), value(_, [Quantity])]),
             value(Tag, [Currency, Total])) :- Total is min(Cents*Quantity, 100000000).

ls_cheaper(A, B, R) :- R is min(A, B).
ls_roundDown(Cents, R) :- R is Cents-(Cents rem 100).
ls_classify(Cents, R) :-
    ( Cents =< 0 -> R = value('shop.tax.v2x0x0.rates::type::Band::Zero', [])
    ; Cents < 10000 -> R = value('shop.tax.v2x0x0.rates::type::Band::Low', [])
    ; R = value('shop.tax.v2x0x0.rates::type::Band::High', [])
    ).
