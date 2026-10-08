%% User-owned LawSpec adapter. Implement these functions.
-module(example_resilience).
-export([
    runtime_exponential_delay/3,
    runtime_linear_delay/3,
    runtime_fibonacci_delay/2,
    split_mix/2,
    full_jitter/2,
    retried_waits/1,
    rejected_waits/1,
    limited_at/1,
    compensations_for/1,
    quote_timed_out/1,
    quote_hedged/1
]).

-spec runtime_exponential_delay(integer(), integer(), integer()) -> integer().

runtime_exponential_delay(_Argument0, _Argument1, _Argument2) ->
    erlang:error({not_implemented, <<"example.resilience::runtimeExponentialDelay"/utf8>>}).

-spec runtime_linear_delay(integer(), integer(), integer()) -> integer().

runtime_linear_delay(_Argument0, _Argument1, _Argument2) ->
    erlang:error({not_implemented, <<"example.resilience::runtimeLinearDelay"/utf8>>}).

-spec runtime_fibonacci_delay(integer(), integer()) -> integer().

runtime_fibonacci_delay(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.resilience::runtimeFibonacciDelay"/utf8>>}).

-spec split_mix(0..18446744073709551615, -2147483648..2147483647) -> [0..18446744073709551615].

split_mix(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.resilience::splitMix"/utf8>>}).

-spec full_jitter(0..18446744073709551615, integer()) -> integer().

full_jitter(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.resilience::fullJitter"/utf8>>}).

-spec retried_waits(-2147483648..2147483647) -> [integer()].

retried_waits(_Argument0) ->
    erlang:error({not_implemented, <<"example.resilience::retriedWaits"/utf8>>}).

-spec rejected_waits(-2147483648..2147483647) -> [integer()].

rejected_waits(_Argument0) ->
    erlang:error({not_implemented, <<"example.resilience::rejectedWaits"/utf8>>}).

-spec limited_at([integer()]) -> [boolean()].

limited_at(_Argument0) -> erlang:error({not_implemented, <<"example.resilience::limitedAt"/utf8>>}).

-spec compensations_for(-9223372036854775808..9223372036854775807) -> [binary()].

compensations_for(_Argument0) ->
    erlang:error({not_implemented, <<"example.resilience::compensationsFor"/utf8>>}).

-spec quote_timed_out(-9223372036854775808..9223372036854775807) -> boolean().

quote_timed_out(_Argument0) ->
    erlang:error({not_implemented, <<"example.resilience::quoteTimedOut"/utf8>>}).

-spec quote_hedged(-9223372036854775808..9223372036854775807) -> boolean().

quote_hedged(_Argument0) ->
    erlang:error({not_implemented, <<"example.resilience::quoteHedged"/utf8>>}).
