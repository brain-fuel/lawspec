%% ref:REQ-harness-units
-module(example_target).
-export([number/1, dependent/2, wide/1]).

number(N) -> true = N >= 0 andalso N =< 1000, beam_target_support:record(<<"number">>, N).
dependent(X, Y) ->
    true = X >= 0 andalso X < 1000 andalso Y > X andalso Y =< 1000,
    beam_target_support:record(<<"dependent">>, [X, Y]), Y.
wide(N) -> beam_target_support:record(<<"wide">>, N).
