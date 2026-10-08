%% ref:DEC-acceptance-with-mutants
-module(beam_failures_exceptions).
-export([declined/1, blocked/0]).
declined(Message) -> erlang:error({refund_declined, Message}).
blocked() -> erlang:error(refund_blocked).
