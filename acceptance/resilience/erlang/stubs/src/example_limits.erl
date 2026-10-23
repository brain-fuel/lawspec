%% User-owned LawSpec adapter. Implement these functions.
-module(example_limits).
-export([
    admit_ticket/1,
    reserve_seat/1,
    charge_card/1,
    release_seat/1,
    fetch_quote/1,
    hedge_quote/1
]).

-spec admit_ticket(lawspec_data:ticket()) -> {left, binary()} | {right, lawspec_data:ticket()}.

admit_ticket(_Ticket) -> erlang:error({not_implemented, <<"example.limits::admitTicket">>}).

-spec reserve_seat(lawspec_data:ticket()) -> {left, binary()} | {right, lawspec_data:ticket()}.

reserve_seat(_Ticket) -> erlang:error({not_implemented, <<"example.limits::reserveSeat">>}).

-spec charge_card(lawspec_data:ticket()) -> {left, binary()} | {right, lawspec_data:ticket()}.

charge_card(_Ticket) -> erlang:error({not_implemented, <<"example.limits::chargeCard">>}).

-spec release_seat(lawspec_data:ticket()) -> boolean().

release_seat(_Ticket) -> erlang:error({not_implemented, <<"example.limits::releaseSeat">>}).

-spec fetch_quote(lawspec_data:ticket()) -> {left, binary()} | {right, lawspec_data:ticket()}.

fetch_quote(_Ticket) -> erlang:error({not_implemented, <<"example.limits::fetchQuote">>}).

-spec hedge_quote(lawspec_data:ticket()) -> {left, binary()} | {right, lawspec_data:ticket()}.

hedge_quote(_Ticket) -> erlang:error({not_implemented, <<"example.limits::hedgeQuote">>}).
