/** <module> Independent native adapters for the shared keywords laws.
ref:DEC-prolog-janus
*/
:- module(example_keywords, [ls__class/2]).

ls__class(X, R) :- R is X*2.
