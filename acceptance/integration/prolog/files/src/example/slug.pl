/** <module> Native slug implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(example_slug, [ls_normalize/2, ls_referenceNormalize/2]).

ls_normalize(X, R) :- string_codes(X, Codes), maplist(slug_code, Codes, Changed), string_codes(R, Changed).
slug_code(Code, R) :- ( Code =:= 32 -> R = 45 ; R = Code ).
ls_referenceNormalize(X, R) :- string_codes(X, Codes), reference_codes(Codes, Changed), string_codes(R, Changed).
reference_codes([], []).
reference_codes([Code|Rest], [Next|Changed]) :-
    ( Code =:= 32 -> Next = 45 ; Next = Code ),
    reference_codes(Rest, Changed).
