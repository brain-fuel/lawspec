%% ref:DEC-acceptance-with-mutants
-module(example_limits).
-export([admit_ticket/1, reserve_seat/1, charge_card/1, release_seat/1, fetch_quote/1, hedge_quote/1]).
admit_ticket(Ticket) -> {right, Ticket}.
reserve_seat(Ticket) -> {right, Ticket}.
charge_card({ticket, N}) when N < 0 -> {left, <<"declined">>};
charge_card(Ticket) -> {right, Ticket}.
release_seat(_) -> true.
fetch_quote({ticket, N} = Ticket) ->
    case N of -1 -> timer:sleep(600); _ -> ok end,
    {right, Ticket}.
hedge_quote({ticket, N} = Ticket) ->
    case N =:= -2 andalso beam_policy_probe:quote_count() rem 2 =:= 1 of
        true -> timer:sleep(600); false -> ok
    end,
    {right, Ticket}.
