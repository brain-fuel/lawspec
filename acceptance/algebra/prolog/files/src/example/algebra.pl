/** <module> Exact arithmetic for the shared algebra laws.
ref:DEC-prolog-janus
*/
:- module(example_algebra,
          [ls_add/3, ls_multiply/3, ls_negateValue/2, ls_maximumValue/3,
           ls_subtractValue/3, ls_divideLeft/3, ls_divideRight/3]).

ls_add(X, Y, R) :- R is X+Y.
ls_multiply(X, Y, R) :- R is X*Y.
ls_negateValue(X, R) :- R is -X.
ls_maximumValue(X, Y, R) :- R is max(X,Y).
ls_subtractValue(X, Y, R) :- R is X-Y.
ls_divideLeft(X, Y, R) :- R is X-Y.
ls_divideRight(X, Y, R) :- R is X+Y.
