/** <module> Native collections, IEEE averages, slugs and typed alternatives.
ref:DEC-prolog-janus
*/
:- module(example_matchers,
          [ls_sortItems/2, ls_uniqueTags/2, ls_average/3, ls_slug/2, ls_ship/2]).
:- use_module(library(janus)).
:- use_module(library(lists)).

ls_sortItems(Items, Sorted) :- msort(Items, Sorted).
ls_uniqueTags(Tags, Unique) :- list_to_set(Tags, Unique).

ls_average(A, B, ieee(Bits)) :-
    Average is (A+B)/2,
    py_call(operator:getitem(eval(struct:unpack(">Q", eval(struct:pack(">d", Average)))), 0), Bits).

ls_slug(Input, R) :-
    string_lower(Input, Lower), string_codes(Lower, Codes),
    words(Codes, Words), atomics_to_string(Words, "-", R).

words(Codes, Words) :-
    skip_separators(Codes, Start),
    ( Start = [] -> Words = []
    ; take_word(Start, Head, Rest), string_codes(Word, Head),
      Words = [Word|Tail], words(Rest, Tail)
    ).
skip_separators(Codes, Rest) :-
    ( Codes = [Code|Tail], \+ word_code(Code) -> skip_separators(Tail, Rest)
    ; Rest = Codes
    ).
take_word(Codes, Word, Rest) :-
    ( Codes = [Code|Tail], word_code(Code) -> Word = [Code|More], take_word(Tail, More, Rest)
    ; Word = [], Rest = Codes
    ).
word_code(Code) :- ( Code >= 97, Code =< 122 -> true ; Code >= 48, Code =< 57 ).

ls_ship(Id, value('example.matchers::type::Order::Shipped',
    [value('lawspec::structural::record::aaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911::Record', ["post", Id])])).
