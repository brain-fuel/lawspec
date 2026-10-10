%% @doc Optional independent audit of calls to the native implementation.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_target_support).
-export([record/2]).
record(Name, Value) ->
    case os:getenv("LAWSPEC_TARGET_AUDIT") of
        false -> ok;
        Path -> ok = file:write_file(Path, [json:encode(#{name => Name, value => Value}), "\n"], [append])
    end,
    Value.
