/** <module> Per-caller replicas with eventual convergence of page views.

Each caller increments its own replica and returns its local count. The
existing Core checker verifies convergence without asserting linearizability.
ref:DEC-prolog-janus
*/
:- module(example_consistency, [ls_newViews/2, ls_hit/2, ls_total/2]).
:- use_module(library(janus)).
:- dynamic memory/1.
:- initialization(init_memory).

init_memory :-
    py_call(builtins:dict(lock=eval(threading:'RLock'()), views=eval(builtins:dict())),
            Memory, [py_object(true)]), assertz(memory(Memory)).

ls_newViews(_, value('example.consistency::type::Views::Views', [Id])) :-
    flag(lawspec_fixture_views_ids, Id, Id+1),
    memory(Memory), py_call(Memory:get(lock), Lock),
    py_call(Memory:get(views), Views, [py_object(true)]),
    setup_call_cleanup(py_call(Lock:acquire()),
        py_call(Views:'__setitem__'(Id, eval(builtins:dict()))), py_call(Lock:release())).
ls_hit(Value, R) :- with_views(Value, hit, R).
ls_total(Value, R) :- with_views(Value, total, R).

with_views(value(_, [Id]), Operation, R) :-
    memory(Memory), py_call(Memory:get(lock), Lock),
    py_call(Memory:get(views), Views, [py_object(true)]),
    py_call(Views:'__getitem__'(Id), Replicas, [py_object(true)]),
    setup_call_cleanup(py_call(Lock:acquire()), operate(Operation, Replicas, R), py_call(Lock:release())).
operate(hit, Replicas, R) :-
    py_call(threading:get_ident(), Caller),
    py_call(Replicas:get(Caller, 0), Previous), R is Previous+1,
    py_call(Replicas:'__setitem__'(Caller, R)).
operate(total, Replicas, R) :- py_call(builtins:sum(eval(Replicas:values())), R).
