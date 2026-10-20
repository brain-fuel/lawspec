/** <module> Exercise the existing host workflow runtime through Janus.

The checked reference definitions remain independent. These adapters call the
runtime under test, including its clocks, retry policy, traces and RNG.
ref:DEC-prolog-janus
*/
:- module(lawspec_05af50e18aa4956b, [ls_runtimeExponentialDelay/4,
    ls_runtimeLinearDelay/4, ls_runtimeFibonacciDelay/3, ls_splitMix/3,
    ls_fullJitter/3, ls_retriedWaits/2, ls_rejectedWaits/2, ls_limitedAt/2,
    ls_compensationsFor/2, ls_quoteTimedOut/2, ls_quoteHedged/2]).
:- use_module(library(janus)).
:- use_module('../lawspec_prolog.pl', []).
:- use_module('limits.pl', []).

ls_runtimeExponentialDelay(Base, Factor, Attempt, Delay) :-
    py_call(lawspec_runtime:retry_delay(-(exponential, Base, Factor, @(none)), Attempt), Delay).
ls_runtimeLinearDelay(Base, Step, Attempt, Delay) :-
    py_call(lawspec_runtime:retry_delay(-(linear, Base, Step), Attempt), Delay).
ls_runtimeFibonacciDelay(Base, Attempt, Delay) :-
    py_call(lawspec_runtime:retry_delay(fibonacci-Base, Attempt), Delay).
ls_splitMix(Seed, Count, Values) :-
    py_call(lawspec_runtime:'SplitMix64'(Seed), Random), random_values(Count, Random, Values).
random_values(Count, Random, Values) :-
    ( Count =< 0 -> Values = []
    ; py_call(Random:next(), Value), Rest is Count-1,
      Values = [Value|Tail], random_values(Rest, Random, Tail)
    ).
ls_fullJitter(Seed, Delay, Result) :-
    py_call(lawspec_runtime:'SplitMix64'(Seed), Random),
    py_call(lawspec_runtime:jittered(full, Delay, 0, 0, Random), Result).

virtual_runtime(Runtime, Symbols) :-
    py_call(lawspec_runtime:'WorkflowRuntime'(eval(lawspec_runtime:'VirtualClock'())), Runtime),
    py_call(Runtime:context(), Symbols, [py_object(true)]).
real_runtime(Runtime, Symbols) :-
    py_call(lawspec_runtime:'WorkflowRuntime'(), Runtime),
    py_call(Runtime:context(), Symbols, [py_object(true)]).

ls_retriedWaits(Attempts, Waits) :- waits(Attempts, @(none), Waits).
ls_rejectedWaits(Attempts, Waits) :-
    py_call(builtins:getattr(eval(builtins:tuple([])), '__contains__'), Reject),
    waits(Attempts, Reject, Waits).
waits(Attempts, When, Waits) :-
    virtual_runtime(Runtime, Symbols),
    py_call(lawspec_runtime:'Retry'(-(exponential, 100000, 2, @(none)), Attempts, none, When), Retry),
    py_call(lawspec_runtime:'StagePolicy'(stage, Retry), Policy),
    py_call(itertools:repeat(eval(lawspec_runtime:'DataValue'('Either::Left', [0]))),
        Failures, [py_object(true)]),
    py_call(builtins:getattr(Failures, '__next__'), Fail),
    py_call(lawspec_runtime:run_stage(Symbols, Policy, Fail), _),
    trace(Runtime, Events), findall(Delay, member(-("sleep", _, Delay), Events), Waits).

ls_limitedAt(Times, Admitted) :-
    virtual_runtime(Runtime, Symbols), maplist(limited_at(Runtime, Symbols), Times, Admitted).
limited_at(Runtime, Symbols, Time, Admitted) :-
    py_call(Runtime:clock, Clock), py_call(builtins:setattr(Clock, time, Time)),
    limited(Symbols, Result),
    ( Result = value('Either::Right', _) -> Admitted = true ; Admitted = false ).
limited(Symbols, Result) :- run_model(Symbols, 'example.limits::limited', 0, Result).

ls_compensationsFor(Number, Stages) :-
    virtual_runtime(Runtime, Symbols), run_model(Symbols, 'example.limits::book', Number, _),
    trace(Runtime, Events), findall(Stage, member(-("compensate", Stage, _), Events), Stages).
ls_quoteTimedOut(Number, TimedOut) :-
    real_runtime(_, Symbols), run_model(Symbols, 'example.limits::quoted', Number, Result),
    ( Result = value('Either::Left',
        [value('example.limits::type::QuotedError::QuotedTimedOut', [])]) -> TimedOut = true
    ; TimedOut = false
    ).
ls_quoteHedged(Number, Quick) :-
    lawspec_048b9363a7f94414:reset_quotes,
    real_runtime(Runtime, Symbols), py_call(time:monotonic(), Started),
    run_model(Symbols, 'example.limits::hedged', Number, Result),
    py_call(time:monotonic(), Finished), trace(Runtime, Events),
    ( Result = value('Either::Right', _), Finished-Started < 0.4,
      ( Number =\= -2 ; memberchk(-("hedge", _, _), Events) ) -> Quick = true
    ; Quick = false
    ).
run_model(Symbols, Identity, Number, Result) :-
    lawspec_prolog:model(context(Symbols), Identity,
        [value('example.limits::type::Ticket::Ticket', [Number])], Result).
trace(Runtime, Events) :- py_call(Runtime:trace, Events, [py_string_as(string)]).
