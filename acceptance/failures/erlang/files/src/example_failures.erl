%% ref:DEC-acceptance-with-mutants
-module(example_failures).
-export([gateway_handler/0, refund/1, settle/1]).

gateway_handler() -> #{decide => fun decide/1}.
decide(N) when N < 0 -> decision_block;
decide(N) when N rem 2 =:= 1 -> {decision_decline, <<"an odd amount">>};
decide(_) -> decision_approve.

refund(N) when N > 5000 -> lawspec_beam_effects:fail({payment_error_too_large, 5000});
refund(N) -> N.

settle(N) when N < 0 -> lawspec_beam_effects:fail(payment_error_blocked);
settle(0) -> lawspec_beam_effects:fail({payment_error_declined, <<"there is nothing to settle">>});
settle(N) -> N.
