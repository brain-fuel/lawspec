/** <module> Independent arithmetic and Boolean implementations.

The checked reference definitions use the existing Python execution backend;
these adapters use Prolog's integer arithmetic and functional predicates.
*/
:- module(lawspec_49c89416dce074eb, [ls_increment/2, ls_flag/2, ls_wideIncrement/2]).

ls_increment(X, R) :- R is X+1.
ls_flag(_, false).
ls_wideIncrement(X, R) :- R is X+1.
