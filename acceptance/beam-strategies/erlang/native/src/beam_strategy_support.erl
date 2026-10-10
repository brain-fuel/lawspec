%% @doc Optional audit records actual adapter calls, including deterministic cases.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_strategy_support).
-export([record/2]).

record(Label, Value) ->
    case os:getenv("LAWSPEC_STRATEGY_AUDIT") of
        false -> ok;
        Path ->
            Name = case is_atom(Label) of true -> atom_to_binary(Label); false -> Label end,
            ok = file:write_file(Path, io_lib:format("~s ~0p~n", [Name, Value]), [append])
    end,
    Value.
