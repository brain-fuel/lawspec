%% @doc Independent audit of actual benchmark callback executions.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_benchmark_support).
-export([record/2]).
record(Name, Value) ->
    case os:getenv("LAWSPEC_BENCHMARK_AUDIT") of
        false -> ok;
        Path -> ok = file:write_file(Path, [json:encode(#{name => Name, value => Value}), "\n"], [append])
    end,
    Value.
