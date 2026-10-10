%% ref:REQ-harness-units
-module(example_status).
-export([ordinary/1, skipped/1, property_bug/1, example_bug/1, finite_bug/1, scored_bug/1,
    open_guard/1, close_guard/1, guard_live/1]).
ordinary(Flag) -> beam_status_support:record(<<"ordinary">>, Flag).
skipped(N) -> beam_status_support:forbidden(N).
property_bug(N) -> beam_status_support:property_bug(N).
example_bug(N) -> beam_status_support:example_bug(N).
finite_bug(Flag) -> beam_status_support:finite_bug(Flag).
scored_bug(N) -> beam_status_support:scored_bug(N).
open_guard(Unit) -> beam_status_support:forbidden(Unit).
close_guard(Guard) -> beam_status_support:forbidden(Guard).
guard_live(Guard) -> beam_status_support:forbidden(Guard).
