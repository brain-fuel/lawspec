/** <module> A production clock bound by module/predicate identity.
ref:DEC-prolog-janus
*/
:- module('example.clocks', [steady/1, steady_now/2, steady_sleep/3]).
:- use_module(library(janus)).

steady(steady(State)) :-
    py_call(time:time_ns(), WallNanos), Wall is WallNanos div 1000,
    py_call(time:monotonic_ns(), Anchor),
    py_call(builtins:dict(readings=0, wall=Wall, anchor=Anchor), State, [py_object(true)]).
steady_now(steady(State), value('lawspec.time::type::Instant::Instant', [Micros])) :-
    py_call(State:get(readings), Previous), Next is Previous+1,
    py_call(State:'__setitem__'(readings, Next)),
    py_call(State:get(wall), Wall), py_call(State:get(anchor), Anchor),
    py_call(time:monotonic_ns(), Nanos), Micros is Wall+(Nanos-Anchor) div 1000.
steady_sleep(_, value(_, [Micros]), absence('Unit')) :- Seconds is Micros/1000000, sleep(Seconds).
