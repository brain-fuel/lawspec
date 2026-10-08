%% @doc Portable workflow policy arithmetic and logical failure values.
%% Durations are integer microseconds. Random state is explicit SplitMix64,
%% separate from the user-facing Random ability's MMIX stream.
%% ref:DEC-typed-core-boundary ref:splitmix
-module(lawspec_beam_policy).
-export([retry_delay/2, jitter/5, retry_decision/1, failed/1, stage_failure/1]).

retry_delay(immediate, Attempt) when Attempt >= 2 -> 0;
retry_delay({fixed, Delay}, Attempt) when Attempt >= 2 -> Delay;
retry_delay({linear, Delay, Step}, Attempt) when Attempt >= 2 -> Delay + Step * (Attempt - 2);
retry_delay({exponential, Delay, Factor, Cap}, Attempt) when Attempt >= 2 ->
    Value = Delay * power(Factor, Attempt - 2),
    case Cap of none -> Value; _ -> min(Value, Cap) end;
retry_delay({fibonacci, Delay}, Attempt) when Attempt >= 2 -> Delay * fibonacci(Attempt - 1, 1, 1).

power(_, 0) -> 1;
power(Base, N) when N rem 2 =:= 0 -> power(Base * Base, N div 2);
power(Base, N) -> Base * power(Base * Base, N div 2).

fibonacci(1, A, _) -> A;
fibonacci(N, A, B) -> fibonacci(N - 1, B, A + B).

jitter(none, Delay, _, _, State) -> {Delay, State};
jitter(full, Delay, _, _, State) -> lawspec_beam_random:below(Delay + 1, State);
jitter(equal, Delay, _, _, State) ->
    Half = Delay div 2,
    {Random, Next} = lawspec_beam_random:below(Delay - Half + 1, State),
    {Half + Random, Next};
jitter(decorrelated, Delay, Previous, Base, State) ->
    High = max(Base, Previous * 3),
    {Random, Next} = lawspec_beam_random:below(High - Base + 1, State),
    {min(Delay, Base + Random), Next}.

retry_decision({ls_data, <<"lawspec.time::type::RetryDecision::RetryAfter">>,
        [{ls_data, <<"lawspec.time::type::Duration::Duration">>, [Delay]}]}) -> {wait, Delay};
retry_decision({ls_data, <<"lawspec.time::type::RetryDecision::Stop">>, []}) -> stop.

failed({ls_data, <<"Either::Left">>, [_]}) -> true;
failed(_) -> false.

stage_failure(Kind) when Kind =:= <<"TimedOut">>; Kind =:= <<"RateLimited">>;
        Kind =:= <<"CircuitOpen">>; Kind =:= <<"Saturated">> ->
    {ls_data, <<"Either::Left">>, [{ls_data, <<"lawspec.resilience::type::StageFailure::", Kind/binary>>, []}]}.
