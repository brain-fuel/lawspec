%% ref:DEC-acceptance-with-mutants
-module(example_beam_failures).
-export([refund/1, checked_limit/1]).

refund(N) when N < 0 -> erlang:error({refund_declined, <<"negative refund">>});
refund(N) when N > 5000 -> lawspec_beam_effects:fail({rejection_limit, 5000});
refund(N) -> N.

checked_limit(N) when N < 0 -> erlang:error(refund_blocked);
checked_limit(N) -> example_beam_failures_definitions:limit(N).
