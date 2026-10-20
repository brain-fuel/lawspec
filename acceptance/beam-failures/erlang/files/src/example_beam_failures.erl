%% ref:DEC-acceptance-with-mutants
-module(example_beam_failures).
-export([refund/1, checked_limit/1]).

refund(N) when N < 0 -> lawspec_beam_effects:fail({rejection_declined, {recordf5f10555f6c6efcfede6a1b5b3a543dda5cd98cceb0297c257aa71c41066c7c7, <<"negative refund">>}});
refund(N) when N > 5000 -> lawspec_beam_effects:fail({rejection_limit, 5000});
refund(N) -> N.

checked_limit(N) -> example_beam_failures_definitions:limit(N).
