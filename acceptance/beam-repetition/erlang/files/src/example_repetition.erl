%% ref:REQ-harness-units
-module(example_repetition).
-export([number/1, finite/1, transient/1, peak/1]).

number(N) -> beam_repetition_support:record(<<"number">>, N).
finite(Flag) -> beam_repetition_support:record(<<"finite">>, Flag).
transient(_) -> beam_repetition_support:transient().
peak(N) -> beam_repetition_support:record(<<"peak">>, N).
