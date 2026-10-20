/** <module> Native saturating duration subtraction in exact microseconds.
ref:DEC-prolog-janus
*/
:- module(lawspec_5fac0451104bd1b5, [ls_remaining/3]).

ls_remaining(value(Tag, [Budget]), value(Tag, [Elapsed]), value(Tag, [R])) :-
    R is max(Budget-Elapsed, 0).
