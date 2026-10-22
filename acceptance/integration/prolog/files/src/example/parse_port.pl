/** <module> Native parse_port implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(lawspec_ac0767fc2fa06496, [ls_validPort/2, ls_render/2, ls_parse/2]).

ls_validPort(X, R) :- ( X >= 1, X =< 65535 -> R = true ; R = false ).
ls_render(X, R) :-
    ( X >= 1, X =< 65535 -> number_string(X, R) ; throw(error(domain_error(port, X), _)) ).
ls_parse(X, R) :- number_string(R, X).
