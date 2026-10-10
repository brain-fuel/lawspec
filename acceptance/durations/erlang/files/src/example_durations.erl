%% ref:DEC-acceptance-with-mutants
-module(example_durations).
-export([remaining/2]).
remaining({duration, Budget}, {duration, Spent}) ->
    {duration, max(Budget - Spent, 0)}.
