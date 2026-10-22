/** <module> Native balanced trees and arithmetic index witnesses.
ref:DEC-prolog-janus
*/
:- module(lawspec_f088f7872c35582a,
          [ls_mirror/2, ls_area/2, ls_duplicate/2, ls_countPairs/2, ls_dropFirst/2]).

ls_mirror(value(Tag, Fields), R) :-
    ( Tag == 'example.arithmetic::type::Perfect::Leaf' -> R = value(Tag, Fields)
    ; Fields = [value(Record, [Left, Right])],
      ls_mirror(Right, A), ls_mirror(Left, B), R = value(Tag, [value(Record, [A, B])])
    ).

ls_area(value(_, [value(_, [Columns, Rows])]), Area) :-
    row_length(Columns, Width), row_length(Rows, Height), Area is Width*Height.

row_length(value(Tag, Fields), Count) :-
    ( Tag == 'example.arithmetic::type::Row::End' -> Count = 0
    ; Fields = [value(_, [_, Tail])], row_length(Tail, Rest), Count is Rest+1
    ).

ls_duplicate(Row, value('example.arithmetic::type::Halves::Halves',
    [value('lawspec::structural::record::90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d::Record', [Row, Row])])).
ls_countPairs(Row, value('example.arithmetic::type::Pairs::Pairs', [Row])).
ls_dropFirst(Row, value('example.arithmetic::type::Rest::Rest', [Row])).
