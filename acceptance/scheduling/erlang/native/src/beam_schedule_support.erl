%% @doc Audit real adapter intervals for the scheduling acceptance gate.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_schedule_support).
-export([pause/1, nap/1]).
pause(N) -> sleep(N, 5).
nap(N) -> sleep(N, 300).
sleep(N, Millis) ->
    record(start, N), timer:sleep(Millis), record('end', N), true.
record(Event, N) ->
    case os:getenv("LAWSPEC_SCHEDULE_LOG") of
        false -> ok;
        Path -> ok = file:write_file(Path,
            io_lib:format("~s ~B ~B~n", [Event, N, erlang:monotonic_time(microsecond)]), [append])
    end.
