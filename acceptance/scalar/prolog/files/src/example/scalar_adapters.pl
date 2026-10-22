/** <module> Exact scalar values across the Prolog boundary.

Decimal addition aligns arbitrary precision integer coefficients. No checked
model or floating-point arithmetic supplies the implementation result.
ref:DEC-prolog-janus
*/
:- module(lawspec_ab50e37251c0eabc,
          [ls_echoChar/2, ls_echoCodePoint/2, ls_echoCodeUnit/2,
           ls_echoBytes/2, ls_echoComplex/2, ls_successor/2, ls_narrow/2,
           ls_addDecimal/3, ls_sameSymbol/3, ls_echoRaw/2, ls_echoPresence/2,
           ls_finish/2, ls_preserveBig/2, ls_machineEcho/2]).
:- use_module(library(janus)).

ls_echoChar(X, X).
ls_echoCodePoint(X, X).
ls_echoCodeUnit(X, X).
ls_echoBytes(X, X).
ls_echoComplex(X, X).
ls_successor(X, R) :- R is X+1.
ls_narrow(X, X).
ls_echoRaw(X, X).
ls_echoPresence(X, X).
ls_finish(_, absence('Unit')).
ls_preserveBig(X, X).
ls_machineEcho(X, X).

ls_sameSymbol(symbol(A), symbol(B), R) :-
    ( A == B -> R = true ; R = false ).

ls_addDecimal(decimal(SA, DA, EA), decimal(SB, DB, EB), decimal(S, Digits, E)) :-
    coefficient(SA, DA, A),
    coefficient(SB, DB, B),
    E is min(EA, EB),
    Sum is A*10^(EA-E)+B*10^(EB-E),
    ( Sum < 0 -> S = 1 ; S = 0 ),
    Magnitude is abs(Sum),
    number_codes(Magnitude, Codes),
    maplist(digit_code, Digits, Codes).

coefficient(Sign, Digits, Value) :-
    foldl(next_digit, Digits, 0, Magnitude),
    ( Sign =:= 1 -> Value is -Magnitude ; Value = Magnitude ).

next_digit(Digit, Previous, Value) :- Value is Previous*10+Digit.
digit_code(Digit, Code) :- Digit is Code-48.
