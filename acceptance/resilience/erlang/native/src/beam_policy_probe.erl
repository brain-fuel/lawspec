%% Native probes of the shared workflow runtime; quote state belongs to one call.
%% ref:DEC-acceptance-with-mutants
-module(beam_policy_probe).
-export([exponential/3, linear/3, fibonacci/2, split_mix/2, full_jitter/2, waits/2,
    monotonic_millis/0, sleep_millis/1, with_quotes/1, first_quote/0, current/0, stall_quote/0, stalled_quote_cancelled/0]).
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
%% A call-local barrier observes the hedge and cancellation, rather than a
%% host-speed deadline. This follows beam_async_probe's blocked-step control
%% and lawspec_beam_attempts' scoped cancellation contract.
with_quotes(Body) ->
    Probe = ets:new(quote_probe, [public, set]),
    try lawspec_beam_workflow:with_runtime(
        #{clock => real, quote_probe => Probe},
        fun(_) -> Body() end)
    after ets:delete(Probe) end.

quote_options() ->
    #{state := State} = current(),
    lawspec_beam_workflow_state:call(State, options).

stall_quote() ->
    %% This is a deadlock guard, not a performance assertion. A working hedge
    %% returns its second result and joins cancellation before this can finish.
    receive release_stalled_quote -> error(stalled_quote_was_released)
    after 10000 -> error(stalled_quote_was_not_hedged) end.

stalled_quote_cancelled() ->
    #{quote_probe := Probe} = quote_options(),
    case ets:lookup(Probe, stalled) of
        [{stalled, Pid}] -> not is_process_alive(Pid);
        [] -> false
    end.
current() -> lawspec_beam_workflow:current(#{}).
first_quote() ->
    %% ETS insert_new/2 atomically chooses and records the first worker, even
    %% if it is cancelled before entering stall_quote/0. See the Erlang ETS
    %% atomicity contract: https://www.erlang.org/doc/apps/stdlib/ets.html#insert_new/2
    %% Ordinary generated laws use a virtual runtime without this probe.
    case maps:find(quote_probe, quote_options()) of
        {ok, Probe} -> ets:insert_new(Probe, {stalled, self()});
        error -> false
    end.
