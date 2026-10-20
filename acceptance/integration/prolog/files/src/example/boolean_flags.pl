/** <module> Native boolean_flags implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(lawspec_d2da7797b4ffce71, [ls_flipFlag/2]).

ls_flipFlag(X, R) :- ( X == true -> R = false ; R = true ).
