%% @doc Workflow policies over the shared checked definitions and BEAM tasks.
%% A scoped runtime owns its state. Without one, workflows share the default
%% runtime; an installed Clock supplies its view of time.
%% ref:DEC-domain-modeling-primitives ref:DEC-async-native-tasks
-module(lawspec_beam_workflow).
-export([with_runtime/2, with_test_runtime/1, with_clock/3, current/1,
    with_virtual/2, with_real/2, with_clock_callbacks/5, native_trace/1, native_sleep/2, native_set_time/2,
    now/1, sleep/2, set_time/2, trace/1, run_stage/4, run_workflow/2]).

with_runtime(Options, Body) -> scoped(Options, true, Body).
with_clock(Clock, Seed, Body) -> with_runtime(#{clock => Clock, seed => Seed}, Body).
with_virtual(Seed, Body) -> with_clock(virtual, Seed, Body).
with_real(Seed, Body) -> with_clock(real, Seed, Body).
with_clock_callbacks(Now, Sleep, Virtual, Seed, Body) ->
    with_clock(#{now => Now, sleep => Sleep, virtual => Virtual}, Seed, Body).
native_trace(Runtime) -> [{event, Kind, Stage, Number, Succeeded}
    || {Kind, Stage, Number, Succeeded} <- trace(Runtime)].
native_sleep(Runtime, Delay) -> sleep(Runtime, Delay), nil.
native_set_time(Runtime, Time) -> set_time(Runtime, Time), nil.
with_test_runtime(Body) ->
    Seed = try list_to_integer(os:getenv("LAWSPEC_SEED", "0")) catch error:badarg -> 0 end,
    scoped(#{clock => virtual, gates => false, seed => Seed}, false, fun(_) -> Body() end).

scoped(Options, Explicit, Body) ->
    {ok, Pid} = lawspec_beam_workflow_state:start(Options),
    Runtime = runtime(Pid, Options, Explicit),
    Key = {?MODULE, runtime}, Previous = put(Key, Runtime),
    try Body(Runtime) after restore(Key, Previous), lawspec_beam_workflow_state:stop(Pid) end.

restore(Key, undefined) -> erase(Key);
restore(Key, Previous) -> put(Key, Previous).
runtime(Pid, Options, Explicit) ->
    #{state => Pid, clock => maps:get(clock, Options, real),
        gates => maps:get(gates, Options, true), explicit => Explicit}.

current(Schema) ->
    Base = case get({?MODULE, runtime}) of
        undefined -> runtime(lawspec_beam_workflow_state:default(), #{}, false);
        Given -> Given
    end,
    case {maps:get(explicit, Base), maps:find(<<"lawspec.time::ability::Clock">>, maps:get(lawspec_handlers, Schema, #{}))} of
        {false, {ok, Handler}} ->
            Base#{clock := #{virtual => not real_clock(Handler),
                now => fun() ->
                    {ls_data, <<"lawspec.time::type::Instant::Instant">>, [Time]} =
                        lawspec_beam_effects:invoke(Handler, Schema, <<"now">>, []), Time
                end,
                sleep => fun(Delay) -> lawspec_beam_effects:invoke(Handler, Schema, <<"sleep">>,
                    [{ls_data, <<"lawspec.time::type::Duration::Duration">>, [Delay]}]) end}};
        _ -> Base
    end.

real_clock({lawspec_recording, _, Inner}) -> real_clock(Inner);
real_clock(Handler) -> Handler =:= lawspec_beam_defaults:handler(<<"lawspec.time::ability::Clock">>).
virtual(#{clock := virtual}) -> true;
virtual(#{clock := real}) -> false;
virtual(#{clock := #{virtual := Virtual}}) -> Virtual.
now(#{clock := real}) -> lawspec_beam_defaults:now_micros();
now(#{clock := virtual} = Runtime) -> state(Runtime, now);
now(#{clock := #{now := Read}}) -> Read().
sleep(_, Delay) when Delay =< 0 -> ok;
sleep(#{clock := real}, Delay) -> lawspec_beam_defaults:sleep_micros(Delay);
sleep(#{clock := virtual} = Runtime, Delay) -> state(Runtime, {sleep, Delay});
sleep(#{clock := #{sleep := Sleep}}, Delay) -> Sleep(Delay), ok.
set_time(#{clock := virtual} = Runtime, Time) -> state(Runtime, {set_time, Time}).
trace(Runtime) -> state(Runtime, trace).
state(#{state := Pid}, Request) -> lawspec_beam_workflow_state:call(Pid, Request).
event(Runtime, Policy, Kind, Number, Succeeded) ->
    state(Runtime, {event, {Kind, maps:get(stage, Policy), Number, Succeeded}}).

run_workflow(Schema, Body) ->
    Runtime = current(Schema),
    Ref = state(Runtime, new_frame),
    Key = {?MODULE, frame}, Previous = put(Key, {maps:get(state, Runtime), Ref}),
    Outcome = try {ok, Body()} catch Class:Reason:Stack -> {exception, Class, Reason, Stack}
        after restore(Key, Previous) end,
    Undos = state(Runtime, {take_frame, Ref}),
    case Outcome of
        {ok, Result} ->
            case lawspec_beam_policy:failed(Result) of
                false -> ok;
                true -> lists:foreach(fun({Stage, Undo}) ->
                    state(Runtime, {event, {<<"compensate">>, Stage, 0, true}}), Undo()
                end, Undos)
            end,
            Result;
        {exception, Class1, Reason1, Stack1} -> erlang:raise(Class1, Reason1, Stack1)
    end.

run_stage(Schema, Given, Body, Input) ->
    Policy = maps:merge(#{key => maps:get(stage, Given), retry => none, timeout => none,
        gates => [], cache => none, wraps => false, compensate => none, hedge => none}, Given),
    Runtime = current(Schema),
    Key = maps:get(key, Policy), TTL = maps:get(cache, Policy), Now = now(Runtime),
    Caching = maps:get(gates, Runtime) andalso TTL =/= none,
    Cached = case Caching of true -> state(Runtime, {cached, Key, Input, Now}); false -> none end,
    case Cached of
        {some, Value} -> event(Runtime, Policy, <<"cached">>, 0, true), Value;
        none ->
            Ref = state(Runtime, {new_stage, Key, Now}),
            Gates = case maps:get(gates, Runtime) of true -> maps:get(gates, Policy); false -> [] end,
            Outcome = try
                Result = case pass_gates(Runtime, Ref, Policy, Gates) of
                    ok -> attempts(Runtime, Policy, Body, 1, 0);
                    {failed, Kind} -> lawspec_beam_policy:stage_failure(Kind)
                end,
                {ok, Result}
            catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end,
            Succeeded = case Outcome of {ok, V} -> not lawspec_beam_policy:failed(V); _ -> false end,
            state(Runtime, {finish_stage, Ref, now(Runtime), Succeeded}),
            case Outcome of
                {exception, Class1, Reason1, Stack1} -> erlang:raise(Class1, Reason1, Stack1);
                {ok, Value} ->
                    case Succeeded of
                        false -> ok;
                        true ->
                            remember_undo(Runtime, Policy, Value),
                            case Caching of true -> state(Runtime, {cache, Key, Input, Value, now(Runtime), TTL}); false -> ok end
                    end,
                    Value
            end
    end.

remember_undo(#{state := Pid} = Runtime, Policy, Result) ->
    case {get({?MODULE, frame}), maps:get(compensate, Policy)} of
        {{Pid, Ref}, Undo} when is_function(Undo, 1) ->
            Value = case Result of {ls_data, <<"Either::Right">>, [Inner]} -> Inner; _ -> Result end,
            state(Runtime, {undo, Ref, maps:get(stage, Policy), fun() -> Undo(Value) end});
        _ -> ok
    end.

pass_gates(_, _, _, []) -> ok;
pass_gates(Runtime, Ref, Policy, [Gate | Rest]) ->
    case pass_gate(Runtime, Ref, Policy, Gate, 0) of
        ok -> pass_gates(Runtime, Ref, Policy, Rest);
        Failure -> Failure
    end.
pass_gate(Runtime, Ref, Policy, Gate, Waited) ->
    Failure = case maps:get(kind, Gate) of breaker -> <<"CircuitOpen">>; limit -> <<"RateLimited">>; bulkhead -> <<"Saturated">> end,
    Decision = state(Runtime, {gate, Ref, Gate, now(Runtime)}),
    Wait = maps:get(wait, Gate),
    case Decision of
        {ls_data, <<"lawspec.resilience::type::Gate::Admit">>, []} -> ok;
        {ls_data, <<"lawspec.resilience::type::Gate::Reject">>, []} -> {failed, Failure};
        _ when Wait =:= none -> {failed, Failure};
        {ls_data, <<"lawspec.resilience::type::Gate::WaitFor">>, [Delay]} ->
            case Wait =/= infinity andalso Waited + Delay > Wait of
                true -> {failed, Failure};
                false ->
                    event(Runtime, Policy, <<"wait">>, Delay, true), sleep(Runtime, Delay),
                    pass_gate(Runtime, Ref, Policy, Gate, Waited + Delay)
            end
    end.

attempts(Runtime, Policy, Body, Number, Previous) ->
    event(Runtime, Policy, <<"start">>, Number, false),
    Result = timed(Runtime, Policy, Body),
    Failed = lawspec_beam_policy:failed(Result),
    event(Runtime, Policy, <<"finish">>, Number, not Failed),
    case {Failed, maps:get(retry, Policy)} of
        {true, Retry} when is_map(Retry) ->
            {ls_data, <<"Either::Left">>, [Error]} = Result,
            case retry_error(maps:get(wraps, Policy), Error) of
                stop -> Result;
                {retry, Reason} ->
                    Count = maps:get(attempts, Retry), Condition = maps:get('when', Retry),
                    case (Count > 0 andalso Number >= Count) orelse
                            (Condition =/= none andalso not Condition(Reason)) of
                        true -> Result;
                        false -> case retry_wait(Runtime, Retry, Number + 1, Reason, Previous) of
                            stop -> Result;
                            {wait, Delay} ->
                                event(Runtime, Policy, <<"sleep">>, Delay, true), sleep(Runtime, Delay),
                                attempts(Runtime, Policy, Body, Number + 1, Delay)
                        end
                    end
            end;
        _ -> Result
    end.

retry_error(false, Error) -> {retry, Error};
retry_error(true, {ls_data, <<"lawspec.resilience::type::StageFailure::StepFailed">>, [Inner]}) -> {retry, Inner};
retry_error(true, {ls_data, <<"lawspec.resilience::type::StageFailure::TimedOut">>, []} = Error) -> {retry, Error};
retry_error(true, _) -> stop.
retry_wait(_, #{strategy := {custom, Decide}}, Number, Error, Previous) -> Decide(Number, Error, Previous);
retry_wait(Runtime, #{strategy := Strategy, jitter := Jitter}, Number, _, Previous) ->
    Delay = lawspec_beam_policy:retry_delay(Strategy, Number),
    Base = lawspec_beam_policy:retry_delay(Strategy, 2),
    {wait, state(Runtime, {jitter, Jitter, Delay, Previous, Base})}.

timed(Runtime, Policy, Body) ->
    Timeout = maps:get(timeout, Policy), Hedge = maps:get(hedge, Policy),
    OnHedge = fun(N) -> event(Runtime, Policy, <<"hedge">>, N, true) end,
    case {virtual(Runtime), maps:get(gates, Runtime)} of
        {true, _} ->
            Began = now(Runtime),
            Result = virtual_hedge(Hedge, Body, OnHedge, 1),
            case Timeout =/= none andalso Timeout > 0 andalso now(Runtime) - Began > Timeout of
                true -> lawspec_beam_policy:stage_failure(<<"TimedOut">>);
                false -> Result
            end;
        {false, false} -> Body();
        {false, true} when Timeout =/= none; Hedge =/= none -> lawspec_beam_attempts:run(Timeout, Hedge, Body, OnHedge);
        _ -> Body()
    end.
virtual_hedge(none, Body, _, _) -> Body();
virtual_hedge({_, Most} = Hedge, Body, Event, Started) ->
    Result = Body(),
    case lawspec_beam_policy:failed(Result) andalso Started < Most of
        false -> Result;
        true -> Event(Started + 1), virtual_hedge(Hedge, Body, Event, Started + 1)
    end.
