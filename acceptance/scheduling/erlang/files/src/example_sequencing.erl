%% ref:REQ-harness-units
-module(example_sequencing).
-export([pause/1]).
pause(N) -> beam_schedule_support:pause(N).
