/** <module> Native vector and tree algorithms checked against index contracts.
ref:DEC-prolog-janus
*/
:- module(lawspec_4bb581caa80bdbab,
          [ls_replicate/3, ls_append/3, ls_zip/3, ls_flatten/2]).

ls_replicate(Count, Item, R) :-
    ( Count =:= 0 -> R = value('example.indexed::type::Vec::VNil', [])
    ; Remaining is Count-1, ls_replicate(Remaining, Item, Tail), cons(Item, Tail, R)
    ).

ls_append(value(Tag, Fields), Other, R) :-
    ( Tag == 'example.indexed::type::Vec::VNil' -> R = Other
    ; Fields = [value(_, [Head, Tail])], ls_append(Tail, Other, Rest), cons(Head, Rest, R)
    ).

ls_zip(value(Tag, Fields), Other, R) :-
    ( Tag == 'example.indexed::type::Vec::VNil' -> R = value(Tag, [])
    ; Fields = [value(_, [_, Tail])], Other = value(_, [value(_, [Head, OtherTail])]),
      ls_zip(Tail, OtherTail, Rest), cons(Head, Rest, R)
    ).

ls_flatten(value(Tag, Fields), R) :-
    ( Tag == 'example.indexed::type::Tree::Tip' -> R = value('example.indexed::type::Vec::VNil', [])
    ; Fields = [value(_, [Left, Right, Item])],
      ls_flatten(Left, A), ls_flatten(Right, B), cons(Item, B, Suffix), ls_append(A, Suffix, R)
    ).

cons(Head, Tail, value('example.indexed::type::Vec::VCons',
    [value('lawspec::structural::record::4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec::Record', [Head, Tail])])).
