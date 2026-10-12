%% The Gleam driver's clock, argument and memory probe.
-module(kafka_bench_ffi).
-export([scale/0, now/0, memory/0, seconds/1, value/0]).

scale() ->
    case init:get_plain_arguments() of
        [N | _] -> list_to_integer(N);
        [] -> 1000000
    end.

now() -> erlang:monotonic_time(microsecond).

value() -> binary:copy(<<"x">>, 64).

seconds(Micros) -> list_to_binary(io_lib:format("~.6f", [Micros / 1.0e6])).

memory() ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    erlang:memory(processes_used) + erlang:memory(binary).
