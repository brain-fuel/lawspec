/** <module> The established host generator against independent portable vectors.
ref:DEC-prolog-janus
*/
:- module(example_generation, [ls_generated/5, ls_shrunk/4]).
:- use_module(library(janus)).

ls_generated(Descriptor, Seed, Size, Count, R) :-
    py_call(lawspec_runtime:generated(Descriptor, Seed, Size, Count), R, [py_string_as(string)]).
ls_shrunk(Descriptor, Seed, Size, R) :-
    py_call(lawspec_runtime:shrunk(Descriptor, Seed, Size), R, [py_string_as(string)]).
