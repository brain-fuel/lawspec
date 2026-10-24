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

runtime_exponential_delay(_Integer, _Integer_2, _Integer_3) ->
    erlang:error({not_implemented, <<"example.resilience::runtimeExponentialDelay">>}).

-spec runtime_linear_delay(integer(), integer(), integer()) -> integer().

runtime_linear_delay(_Integer, _Integer_2, _Integer_3) ->
    erlang:error({not_implemented, <<"example.resilience::runtimeLinearDelay">>}).

-spec runtime_fibonacci_delay(integer(), integer()) -> integer().

runtime_fibonacci_delay(_Integer, _Integer_2) ->
    erlang:error({not_implemented, <<"example.resilience::runtimeFibonacciDelay">>}).

-spec split_mix(0..18446744073709551615, -2147483648..2147483647) -> [0..18446744073709551615].

split_mix(_UInt64, _Int32) -> erlang:error({not_implemented, <<"example.resilience::splitMix">>}).

-spec full_jitter(0..18446744073709551615, integer()) -> integer().

full_jitter(_UInt64, _Integer) ->
    erlang:error({not_implemented, <<"example.resilience::fullJitter">>}).

-spec retried_waits(-2147483648..2147483647) -> [integer()].

retried_waits(_Int32) -> erlang:error({not_implemented, <<"example.resilience::retriedWaits">>}).

-spec rejected_waits(-2147483648..2147483647) -> [integer()].

rejected_waits(_Int32) -> erlang:error({not_implemented, <<"example.resilience::rejectedWaits">>}).

-spec limited_at([integer()]) -> [boolean()].

limited_at(_ListInteger) -> erlang:error({not_implemented, <<"example.resilience::limitedAt">>}).

-spec compensations_for(-9223372036854775808..9223372036854775807) -> [binary()].

compensations_for(_Int64) ->
    erlang:error({not_implemented, <<"example.resilience::compensationsFor">>}).

-spec quote_timed_out(-9223372036854775808..9223372036854775807) -> boolean().

quote_timed_out(_Int64) -> erlang:error({not_implemented, <<"example.resilience::quoteTimedOut">>}).

-spec quote_hedged(-9223372036854775808..9223372036854775807) -> boolean().

quote_hedged(_Int64) -> erlang:error({not_implemented, <<"example.resilience::quoteHedged">>}).
