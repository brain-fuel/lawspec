%% ref:DEC-acceptance-with-mutants
-module(example_resilience).
-export([runtime_exponential_delay/3, runtime_linear_delay/3, runtime_fibonacci_delay/2,
    split_mix/2, full_jitter/2, retried_waits/1, rejected_waits/1, limited_at/1,
    compensations_for/1, quote_timed_out/1, quote_hedged/1]).
runtime_exponential_delay(Base, Factor, Attempt) ->
    lawspec_beam_policy:retry_delay({exponential, Base, Factor, none}, Attempt).
runtime_linear_delay(Base, Step, Attempt) -> lawspec_beam_policy:retry_delay({linear, Base, Step}, Attempt).
runtime_fibonacci_delay(Base, Attempt) -> lawspec_beam_policy:retry_delay({fibonacci, Base}, Attempt).
split_mix(Seed, Count) -> beam_policy_probe:split_mix(Seed, Count).
full_jitter(Seed, Delay) -> beam_policy_probe:full_jitter(Seed, Delay).
retried_waits(Attempts) -> beam_policy_probe:waits(Attempts, true).
rejected_waits(Attempts) -> beam_policy_probe:waits(Attempts, false).
limited_at(Times) -> lawspec_beam_workflow:with_virtual(0, fun(Runtime) ->
    [begin lawspec_beam_workflow:set_time(Runtime, Time),
        case example_limits_definitions:limited({ticket, 0}) of {right, _} -> true; _ -> false end
    end || Time <- Times]
end).
compensations_for(N) -> lawspec_beam_workflow:with_virtual(0, fun(Runtime) ->
    example_limits_definitions:book({ticket, N}),
    [Name || {<<"compensate">>, Name, _, _} <- lawspec_beam_workflow:trace(Runtime)]
end).
quote_timed_out(N) -> lawspec_beam_workflow:with_real(0, fun(_) ->
    example_limits_definitions:quoted({ticket, N}) =:= {left, quoted_error_quoted_timed_out}
end).
quote_hedged(N) -> beam_policy_probe:with_quotes(fun() ->
    Runtime = lawspec_beam_workflow:current(#{}), Start = erlang:monotonic_time(millisecond),
    Result = example_limits_definitions:hedged({ticket, N}),
    Quick = erlang:monotonic_time(millisecond) - Start < 400,
    Hedged = lists:any(fun({Kind, _, _, _}) -> Kind =:= <<"hedge">> end, lawspec_beam_workflow:trace(Runtime)),
    Result =:= {right, {ticket, N}} andalso Quick andalso (N =/= -2 orelse Hedged)
end).
