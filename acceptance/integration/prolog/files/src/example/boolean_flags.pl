/** <module> Native boolean_flags implementation for integration laws.
ref:DEC-prolog-janus
*/
:- module(example_boolean_flags, [ls_flipFlag/2]).

ls_flipFlag(X, R) :- ( X == true -> R = false ; R = true ).
