/** <module> Native atoi_codec implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(lawspec_af830c373baed16f, [ls_itoa/2, ls_atoi/2]).

ls_itoa(X, R) :- number_string(X, R).
ls_atoi(X, R) :- number_string(R, X).
