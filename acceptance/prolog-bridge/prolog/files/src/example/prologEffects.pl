/** <module> Ability delegation and an application-owned production ledger.

The instance token holds independent mutable state. Explicit operation calls
remain observable to the generated recording handler and checked model.
*/
:- module(example_prolog_effects, [ls_execute/3, ls_twice/3, ls_contextCheck/2,
    handler_LedgerHandler_new/1, handler_LedgerHandler_add/3]).
:- use_module(library(janus)).
:- use_module('../lawspec_models/example/prologEffects.pl', []).

ls_execute(H, N, R) :- lawspec_prolog:operation(H, add, [N], R).
ls_twice(H, N, R) :-
    lawspec_prolog:operation(H, add, [N], _),
    lawspec_prolog:operation(H, add, [N], R).
ls_contextCheck(Unit, R) :-
    lawspec_prolog:new_context(Context),
    example_prolog_effects_model:ls_symbolValue(Context, Unit, First),
    example_prolog_effects_model:ls_symbolValue(Context, Unit, Second),
    ( First == Second -> R=true ; R=false ).

handler_LedgerHandler_new(Token) :- py_call(builtins:list([0]), Token, [py_object(true)]).
handler_LedgerHandler_add(_, 0, _) :- !,
    throw(lawspec_failure(value('example.prologEffects::type::Refusal::Blocked', []))).
handler_LedgerHandler_add(Token, N, R) :-
    py_call(Token:'__getitem__'(0), Previous),
    R is Previous+N,
    py_call(Token:'__setitem__'(0, R)).
