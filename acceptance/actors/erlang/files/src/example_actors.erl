%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(example_actors).
-export([open_account/1, deposit/2, withdraw_all/1, balance/1, close/1, reopen/1,
    deposit_twice/1, survives_crash/1, native_probe/1]).

native_probe(ok) -> beam_actor_api_probe:probe().

open_account(ok) -> {account, 0}.
deposit({account, Balance}, Amount) -> {pair, Balance + Amount, {account, Balance + Amount}}.
withdraw_all({account, Balance}) -> {pair, Balance, {account, 0}}.
balance({account, Balance} = State) -> {pair, Balance, State}.
close(_) -> {account, 0}.
reopen(State) -> State.

deposit_twice(Amount) ->
    Actor = lawspec_actor_example_actors_account:start(),
    try
        lawspec_beam_runtime:concurrently([
            fun() -> lawspec_actor_example_actors_account:deposit(Actor, Amount) end,
            fun() -> lawspec_actor_example_actors_account:deposit(Actor, Amount) end]),
        lawspec_actor_example_actors_account:balance(Actor)
    after lawspec_actor_example_actors_account:stop(Actor) end.

survives_crash(Amount) ->
    Bank = lawspec_supervisor_example_actors_bank:start(),
    Actor = lawspec_supervisor_example_actors_bank:account(Bank),
    try
        lawspec_actor_example_actors_account:deposit(Actor, Amount),
        lawspec_actor_example_actors_account:crash(Actor),
        lawspec_actor_example_actors_account:balance(Actor)
    after lawspec_supervisor_example_actors_bank:stop(Bank) end.
