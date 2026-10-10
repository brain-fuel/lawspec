%% @doc Audit every native call, independent of the generated statistics.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_repetition_support).
-export([record/2, transient/0]).
record(Name, Value) ->
    Key = {?MODULE, Name},
    Count = case get(Key) of undefined -> 1; Previous -> Previous + 1 end,
    put(Key, Count),
    case os:getenv("LAWSPEC_REPETITION_AUDIT") of
        false -> ok;
        Path -> ok = file:write_file(Path, [json:encode(#{name => Name, value => Value,
            process => list_to_binary(pid_to_list(self())), call => Count}), "\n"], [append])
    end,
    Value.

transient() ->
    Succeeds = get({?MODULE, <<"transient">>}) =/= undefined,
    record(<<"transient">>, Succeeds).
