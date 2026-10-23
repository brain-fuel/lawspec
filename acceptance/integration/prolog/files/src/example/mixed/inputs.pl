/** <module> Independent text and integer adapters with mixed unused inputs.
ref:DEC-prolog-janus
*/
:- module(example_mixed_inputs, [ls_normalize/2, ls_identity/2]).
ls_identity(X, X).
ls_normalize(X, R) :- string_codes(X, Codes), maplist(normalized_code, Codes, Result), string_codes(R, Result).
normalized_code(Code, R) :- ( Code =:= 32 -> R = 45 ; R = Code ).
