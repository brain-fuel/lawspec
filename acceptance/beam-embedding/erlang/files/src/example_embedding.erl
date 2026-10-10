%% User-owned LawSpec adapter: an application that makes spec handlers itself.
-module(example_embedding).
-export([embed/1, share_book/1, tally_handler/0, ledger_handler/0, balance_handler/0]).

-spec embed(integer()) -> integer().
embed(N) ->
    lawspec_abilities:with_context(fun(Context) ->
        Tally = lawspec_abilities_example_embedding:keeping(Context),
        ok = lawspec_abilities_example_embedding:keeping_set_state(Tally, 10),
        {error, refusal_negative} = lawspec_abilities_example_embedding:tally_try_add(Tally, -1),
        {ok, _} = lawspec_abilities_example_embedding:tally_try_add(Tally, N),
        lawspec_abilities_example_embedding:keeping_state(Tally)
    end).

-spec share_book(integer()) -> integer().
share_book(N) ->
    lawspec_abilities:with_context(fun(Context) ->
        {Ledger, Balance} = lawspec_abilities_example_embedding:book(Context),
        ok = (maps:get(record, Ledger))(N),
        (maps:get(balance, Balance))()
    end).

-spec tally_handler() -> lawspec_abilities_example_embedding:tally().
tally_handler() -> #{add => fun(N) -> N end}.

-spec ledger_handler() -> lawspec_abilities_example_embedding:ledger().
ledger_handler() -> #{record => fun(_) -> ok end}.

-spec balance_handler() -> lawspec_abilities_example_embedding:balance().
balance_handler() -> #{balance => fun() -> 0 end}.
