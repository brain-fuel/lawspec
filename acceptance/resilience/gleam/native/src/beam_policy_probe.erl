%% Native probes of the shared workflow runtime; quote state belongs to one call.
%% ref:DEC-acceptance-with-mutants
-module(beam_policy_probe).
-export([exponential/3, linear/3, fibonacci/2, split_mix/2, full_jitter/2, waits/2,
    monotonic_millis/0, sleep_millis/1, with_quotes/1, quote_count/0, current/0]).
exponential(Base, Factor, Attempt) -> lawspec_beam_policy:retry_delay({exponential, Base, Factor, none}, Attempt).
linear(Base, Step, Attempt) -> lawspec_beam_policy:retry_delay({linear, Base, Step}, Attempt).
fibonacci(Base, Attempt) -> lawspec_beam_policy:retry_delay({fibonacci, Base}, Attempt).
split_mix(Seed, Count) -> randoms(lawspec_beam_random:seed(Seed), Count, []).
randoms(_, Count, Values) when Count =< 0 -> lists:reverse(Values);
randoms(State, Count, Values) ->
    {N, Next} = lawspec_beam_random:next(State), randoms(Next, Count - 1, [N | Values]).
full_jitter(Seed, Delay) ->
    {N, _} = lawspec_beam_policy:jitter(full, Delay, 0, 0, lawspec_beam_random:seed(Seed)), N.
waits(Attempts, Accepts) ->
    lawspec_beam_workflow:with_virtual(0, fun(Runtime) ->
        Retry = #{strategy => {exponential, 100000, 2, none}, attempts => Attempts,
            jitter => none, 'when' => fun(_) -> Accepts end},
        lawspec_beam_workflow:run_stage(#{}, #{stage => <<"stage">>, retry => Retry},
            fun() -> {ls_data, <<"Either::Left">>, [0]} end, ls_unit),
        [Delay || {<<"sleep">>, _, Delay, _} <- lawspec_beam_workflow:trace(Runtime)]
    end).
monotonic_millis() -> erlang:monotonic_time(millisecond).
sleep_millis(Millis) -> timer:sleep(Millis), nil.
with_quotes(Body) ->
    lawspec_beam_workflow:with_runtime(#{clock => real, quotes => atomics:new(1, [])}, fun(_) -> Body() end).
current() -> lawspec_beam_workflow:current(#{}).
quote_count() ->
    #{state := State} = current(),
    Options = lawspec_beam_workflow_state:call(State, options),
    %% Only the explicit real-clock hedge probe stalls an attempt. Ordinary
    %% generated laws run under a fresh virtual runtime without this counter.
    case maps:find(quotes, Options) of
        {ok, Count} -> atomics:add_get(Count, 1, 1);
        error -> 0
    end.
