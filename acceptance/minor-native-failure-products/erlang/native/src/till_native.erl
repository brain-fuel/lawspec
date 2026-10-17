%% A production handler uses application Cash; a bound adapter receives the
%% generated Drawer interface, whose operations use canonical Money.
-module(till_native).
-export([new_native_till/0, pay/2]).

new_native_till() ->
    Taken = lawspec_beam_effects:native_cell(0),
    #{take => fun({cash, Cents}) ->
          _ = lawspec_beam_effects:native_write(Taken, lawspec_beam_effects:native_read(Taken) + Cents),
          {cash, Cents}
      end,
      opening => fun() -> {cash, 0} end}.

pay(_, Cents) when Cents < 0 -> erlang:error({bad_amount, <<"negative">>});
pay(_, Cents) when Cents > 1000 -> erlang:error(card_declined);
pay(Drawer, Cents) ->
    {money, Paid} = (maps:get(take, Drawer))({money, Cents}),
    {cash, Paid}.
