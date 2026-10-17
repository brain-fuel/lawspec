-module(till_native_errors).
-export([declined/0, bad_amount/1]).
declined() -> erlang:error(card_declined).
bad_amount(Message) -> erlang:error({bad_amount, Message}).
