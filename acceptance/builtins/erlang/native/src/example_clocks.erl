-module(example_clocks).
-export([steady_clock/0]).

steady_clock() ->
    #{now := Now, sleep := Sleep} = lawspec_time:clock_handler(),
    Readings = lawspec_beam_effects:native_cell(0),
    #{now => fun() ->
        _Count = lawspec_beam_handler:call(Readings, fun(N) -> {N + 1, N + 1} end),
        {instant, Micros} = Now(),
        {instant, Micros}
    end, sleep => Sleep}.
