%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(example_restarts).
-export([open_tab/1, add/2, total/1, keeps_total/1]).

open_tab(ok) -> {tab, 0}.
add({tab, Total}, Amount) -> {pair, Total + Amount, {tab, Total + Amount}}.
total({tab, Total} = State) -> {pair, Total, State}.

keeps_total(Amount) ->
    Bar = lawspec_supervisor_example_restarts_bar:start(),
    Actor = lawspec_supervisor_example_restarts_bar:tab(Bar),
    try
        lawspec_actor_example_restarts_tab:add(Actor, Amount),
        lawspec_actor_example_restarts_tab:crash(Actor),
        lawspec_actor_example_restarts_tab:total(Actor)
    after lawspec_supervisor_example_restarts_bar:stop(Bar) end.
