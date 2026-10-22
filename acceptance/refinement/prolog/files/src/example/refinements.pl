/** <module> Independent native adapters for the shared refinement laws.
ref:DEC-prolog-janus
*/
:- module(lawspec_dcef2481641ce4a9, [ls_add/3, ls_successor/2, ls_count/2, ls_preserve/2, ls_positive/2, ls_abstractEcho/2]).

ls_add(X, Y, R) :- R is X+Y.
ls_successor(X, R) :- R is X+1.
ls_count(Text, N) :- string_length(Text, N).
ls_preserve(X, X).
ls_positive(X, X).
ls_abstractEcho(X, X).
