/** <module> Shared counter with native worker attachment and explicit locking.

The application lock belongs to Python so callbacks do not invert the Janus
GIL and Prolog mutex order. A logical handle preserves the counter's identity.
*/
:- module(example_prolog_async, [ls_newCounter/2, ls_increment/2, ls_read/2]).
:- use_module(library(janus)).

ls_newCounter(_, opaque(State)) :-
    py_call(builtins:dict(count=0, lock=eval(threading:'RLock'())), State, [py_object(true)]).
ls_increment(Counter, R) :- with_counter(Counter, 1, R).
ls_read(Counter, R) :- with_counter(Counter, 0, R).
with_counter(opaque(Holder), Delta, R) :-
    lawspec_prolog:native_handle(opaque(Holder), State),
    py_call(State:get(lock), Lock),
    setup_call_cleanup(py_call(Lock:acquire()), update(State, Delta, R), py_call(Lock:release())).
update(State, Delta, R) :-
    py_call(State:get(count), Old), R is Old+Delta, py_call(State:'__setitem__'(count, R)).
