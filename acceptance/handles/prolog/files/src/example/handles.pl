/** <module> A native deque behind an opaque shared handle.

The Python RLock protects each complete operation and follows Janus's documented
GIL/mutex ordering. Queue algorithms and state belong to this adapter.
ref:DEC-prolog-janus
*/
:- module(example_handles,
          [ls_newJobs/2, ls_submit/3, ls_take/2, ls_pending/2]).
:- use_module(library(janus)).

ls_newJobs(_, opaque(State)) :-
    py_call(builtins:dict(items=eval(collections:deque()), lock=eval(threading:'RLock'())),
            State, [py_object(true)]).

ls_submit(Handle, Item, absence('Unit')) :- with_jobs(Handle, submit(Item), _).
ls_take(Handle, R) :- with_jobs(Handle, take, R).
ls_pending(Handle, R) :- with_jobs(Handle, pending, R).

with_jobs(opaque(Holder), Operation, R) :-
    lawspec_prolog:native_handle(opaque(Holder), State),
    py_call(State:get(lock), Lock),
    py_call(State:get(items), Items, [py_object(true)]),
    setup_call_cleanup(py_call(Lock:acquire()), queue_operation(Operation, Items, R),
                       py_call(Lock:release())).

queue_operation(submit(Item), Items, absence('Unit')) :- py_call(Items:append(Item)).
queue_operation(pending, Items, Count) :- py_call(builtins:len(Items), Count).
queue_operation(take, Items, R) :-
    py_call(builtins:len(Items), Count),
    ( Count =:= 0 -> R = value('Maybe::Absent', [])
    ; py_call(Items:popleft(), Item), R = value('Maybe::Present', [Item])
    ).
