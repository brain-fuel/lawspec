/** <module> Native canonical_url implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(example_canonical_url, [ls_canonicalize/2]).

ls_canonicalize(X, R) :-
    string_codes(X, Codes), reverse(Codes, Reversed),
    without_slashes(Reversed, Trimmed), reverse(Trimmed, Result), string_codes(R, Result).
without_slashes(Codes, R) :- ( Codes = [47|Rest] -> without_slashes(Rest, R) ; R = Codes ).
