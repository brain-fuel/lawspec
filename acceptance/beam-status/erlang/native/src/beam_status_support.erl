%% @doc Native failures and independent auditing of executed adapter calls.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_status_support).
-export([record/2, forbidden/1, property_bug/1, example_bug/1, finite_bug/1, scored_bug/1]).
record(Name, Value) ->
    case os:getenv("LAWSPEC_STATUS_AUDIT") of
        false -> ok;
        Path -> ok = file:write_file(Path, [json:encode(#{name => Name, value => Value}), "\n"], [append])
    end,
    Value.

forbidden(_) -> record(<<"forbidden">>, true), error(skipped_law_executed).
property_bug(N) -> record(<<"property">>, N), case N of 7 -> 0; _ -> N end.
example_bug(N) -> record(<<"example">>, N), case N of 9 -> 0; _ -> N end.
finite_bug(Flag) -> record(<<"finite">>, Flag), not Flag.
scored_bug(N) -> record(<<"scored">>, N), case N of 7 -> 0; _ -> N end.
