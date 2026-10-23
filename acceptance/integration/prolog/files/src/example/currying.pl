/** <module> Native multi-argument functions for the currying laws.
ref:DEC-prolog-janus
*/
:- module(example_currying,
          [ls_sumFour/5, ls_format/5, ls_referenceFormat/5, ls_trim/2]).

ls_sumFour(A, B, C, D, R) :- R is A+B+C+D.

ls_format(Prefix, Enabled, Port, Suffix, R) :-
    ( Enabled == true -> number_string(Port, Middle) ; Middle = "" ),
    string_concat(Prefix, Middle, Start),
    string_concat(Start, Suffix, R).

ls_referenceFormat(Prefix, Enabled, Port, Suffix, R) :-
    ( Enabled == true -> Parts = [Prefix, Port, Suffix] ; Parts = [Prefix, Suffix] ),
    atomics_to_string(Parts, R).

% Unicode White_Space plus the four ASCII information separators, as str.strip.
ls_trim(Input, R) :-
    string_codes(Input, Codes),
    trim_front(Codes, Left),
    reverse(Left, Reversed),
    trim_front(Reversed, Right),
    reverse(Right, Trimmed),
    string_codes(R, Trimmed).

trim_front(Codes, Trimmed) :-
    ( Codes = [Code|Rest], whitespace(Code) -> trim_front(Rest, Trimmed)
    ; Trimmed = Codes
    ).

whitespace(Code) :-
    ( Code >= 9, Code =< 13 -> true
    ; Code >= 28, Code =< 32 -> true
    ; Code >= 8192, Code =< 8202 -> true
    ; memberchk(Code, [133,160,5760,8232,8233,8239,8287,12288])
    ).
