%% ref:REQ-harness-units
-module(example_adequacy).
-export([number/1, dependent/2, finite/1]).

number(N) -> beam_adequacy_support:record(<<"number">>, N).
dependent(X, Y) -> beam_adequacy_support:record(<<"dependent">>, [X, Y]), Y.
finite(Flag) -> beam_adequacy_support:record(<<"finite">>, Flag).
