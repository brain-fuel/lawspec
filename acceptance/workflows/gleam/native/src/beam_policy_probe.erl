%% ref:DEC-acceptance-with-mutants
-module(beam_policy_probe).
-export([monotonic_millis/0, sleep_millis/1]).
monotonic_millis() -> erlang:monotonic_time(millisecond).
sleep_millis(Millis) -> timer:sleep(Millis), nil.
