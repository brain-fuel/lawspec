/** <module> Native alternatives implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(example_alternatives, [ls_render/2, ls_referenceRender/2, ls_clamp/2, ls_referenceClamp/2]).

ls_render(X, R) :- number_string(X, R).
ls_referenceRender(X, R) :- format(string(R), "~d", [X]).
ls_clamp(X, R) :- R is max(0, X).
ls_referenceClamp(X, R) :- ( X < 0 -> R = 0 ; R = X ).
