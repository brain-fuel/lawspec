%% ref:DEC-never-pass-vacuously ref:DEC-tests-cite-requirements
-module(beam_selection_support).
-export([record/1]).
record(N) ->
    case os:getenv("LAWSPEC_SELECTION_AUDIT") of
        false -> ok;
        Path -> ok = file:write_file(Path, [integer_to_binary(N), "\n"], [append])
    end,
    N.
