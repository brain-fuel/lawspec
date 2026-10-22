/** <module> Native money records, a production till and native exceptions.
ref:DEC-prolog-janus
*/
:- module('till.native', [pay/3, 'NativeTill'/1, 'NativeTill_take'/3, 'NativeTill_opening'/2]).

'NativeTill'(till(Id)) :-
    flag(lawspec_native_till_ids, Id, Id+1), till_key(Id, Key), flag(Key, _, 0).
'NativeTill_take'(till(Id), Money, Cash) :-
    is_dict(Money, 'till.native.Cash'), get_dict(cents, Money, Cents),
    till_key(Id, Key), flag(Key, Taken, Taken+Cents),
    Cash = 'till.native.Cash'{cents:Cents}.
'NativeTill_opening'(till(_), 'till.native.Cash'{cents:0}).
till_key(Id, Key) :- atomic_list_concat([native_till_, Id], Key).

pay(Till, Cents, Cash) :-
    ( Cents < 0 -> throw('till.native.BadAmount'("negative"))
    ; Cents > 1000 -> throw('till.native.CardDeclined')
    ; lawspec_prolog:operation(Till, take, ['till.native.Cash'{cents:Cents}], Cash)
    ).
