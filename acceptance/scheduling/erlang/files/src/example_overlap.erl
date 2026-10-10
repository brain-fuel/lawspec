%% ref:REQ-harness-units
-module(example_overlap).
-export([nap/1]).
nap(N) -> beam_schedule_support:nap(N).
