%% @doc Scenarios preserve message causality, delegated ownership, failures
%% and real model calls while varying scheduling and crashed processes.
%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(lawspec_beam_scenario_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

spec(Channels, Mailboxes, Body) -> iolist_to_binary([
    <<"(scenario \"a scenario\" counter) (channels ">>, Channels,
    <<") (mailboxes ">>, Mailboxes, <<") (process ">>, Body, <<")">>]).
counter(Actor) -> lawspec_beam_model_tests:counter(Actor).
run(Model, Spec) -> lawspec_beam_scenario:run(Model, Spec, 42, #{}).
every_crash(Model, Spec) ->
    Program = lawspec_beam_scenario:new(Spec),
    lists:foreach(fun({Id, N}) -> lists:foreach(fun(At) ->
        ?assertEqual(ok, lawspec_beam_scenario:execute(Model, Program, At, #{victim => {Id, At}}))
    end, lists:seq(0, N)) end, maps:get(branches, Program)).

message_clocks_order_native_model_calls_test() ->
    S = spec("c", "", <<"(par (process (call add x (int 5)) (send c (var x)))
        (process (receive c y) (expect y (int 5)) (call read z) (expect z (int 5))))">>),
    lists:foreach(fun(Mode) ->
        {ok, #{history := [A, B], final := {some, 5}}} = run((counter(false))#{consistency := Mode}, S),
        ?assert(lawspec_beam_history:happened_before(A, B)),
        ?assertNot(lawspec_beam_history:happened_before(B, A))
    end, [<<"linearizable">>, <<"sequential">>, <<"causal">>, <<"eventual">>]),
    every_crash(counter(false), S), every_crash(counter(true), S).

delegated_reply_reaches_its_new_owner_test() ->
    S = spec("ask answer", "", <<"(par (process (send ask (var answer)))
        (process (receive ask reply) (call add x (int 5)) (send reply (var x)))
        (process (receive answer y) (expect y (int 5)) (call read z) (expect z (int 5))))">>),
    ?assertMatch({ok, #{final := {some, 5}}}, run(counter(false), S)),
    every_crash(counter(false), S), every_crash(counter(true), S).

delegated_mailbox_reply_is_released_if_receiver_crashes_test() ->
    S = spec("answer", "requests", <<"(par (process (send requests (var answer)))
        (process (receive requests reply) (call add x (int 5)) (send reply (var x)))
        (process (receive answer y) (expect y (int 5))))">>),
    ?assertMatch({ok, #{final := {some, 5}}}, run(counter(false), S)),
    every_crash(counter(false), S).

fork_join_clocks_include_every_child_test() ->
    S = spec("", "", <<"(par (process (call add _ (int 3))) (process (call add _ (int 4))))
        (call read total) (expect total (int 7))">>),
    {ok, #{history := [A, B, C], final := {some, 7}}} = run(counter(false), S),
    ?assert(lawspec_beam_history:happened_before(A, C)),
    ?assert(lawspec_beam_history:happened_before(B, C)),
    ?assertNot(lawspec_beam_history:happened_before(A, B)),
    ?assertNot(lawspec_beam_history:happened_before(B, A)),
    every_crash(counter(false), S), every_crash(counter(true), S).

safe_channel_cycle_executes_test() ->
    S = spec("out back", "", <<"(par
        (process (call add n (int 5)) (send out (var n)) (receive back m) (expect m (int 5)))
        (process (receive out n) (send back (var n))))">>),
    ?assertMatch({ok, #{final := {some, 5}}}, run(counter(false), S)), every_crash(counter(false), S).

or_else_runs_instead_of_remainder_test() ->
    S = spec("c", "", <<"(par (process (call add n (int 5)) (send c (var n)))
        (process (receiveor c m (process (call add _ (int 10)))) (expect m (int 5))))">>),
    ?assertMatch({ok, #{final := {some, 5}}}, run(counter(true), S)),
    ?assertMatch({ok, #{outcome := failed, final := {some, 10}}},
        lawspec_beam_scenario:run(counter(true), S, 0, #{victim => {1, 0}})),
    ?assertMatch({ok, #{outcome := failed, final := {some, 15}}},
        lawspec_beam_scenario:run(counter(true), S, 0, #{victim => {1, 1}})),
    every_crash(counter(true), S).

mailbox_clocks_follow_each_value_test() ->
    S = spec("", "reports", <<"(par
        (process (call add a (int 3)) (send reports (var a)))
        (process (call add b (int 4)) (send reports (var b)))
        (process (receive reports first) (receive reports second) (call read total) (expect total (int 7))))">>),
    {ok, #{history := [A, B, C]}} = run(counter(true), S),
    ?assert(lawspec_beam_history:happened_before(A, C)),
    ?assert(lawspec_beam_history:happened_before(B, C)),
    every_crash(counter(true), S).

crash_before_nested_par_releases_descendant_sends_test() ->
    S = spec("", "m", <<"(par
        (process (par (process (send m (int 3))) (process (send m (int 4)))))
        (process (receive m first) (receive m second)))">>),
    Program = lawspec_beam_scenario:new(S),
    ?assertEqual([{1, 1}, {2, 1}, {3, 1}, {4, 2}], maps:get(branches, Program)),
    ?assertMatch({ok, _}, run(counter(false), S)),
    Before = erlang:monotonic_time(millisecond),
    every_crash(counter(false), S),
    ?assert(erlang:monotonic_time(millisecond) - Before < 1000).

expectation_failure_is_not_masked_by_crash_test() ->
    S = spec("", "", <<"(call read x) (expect x (int 42)) (par (process) (process))">>),
    ?assertMatch({error, #{reason := {raised, error, {lawspec, {scenario_expectation, <<"x">>, 0, 42}}}}},
        lawspec_beam_scenario:run(counter(false), S, 0, #{crash => true})).

incorrect_native_results_are_rejected_test() ->
    M0 = counter(false),
    Read = (lawspec_beam_model:command(M0, 1))#{run := fun(_, [S]) -> atomics:get(S, 1) + 1 end},
    M = M0#{steps := setelement(2, maps:get(steps, M0), Read)},
    S = spec("", "", <<"(call add _ (int 5)) (call read x)">>),
    ?assertMatch({error, #{reason := no_consistent_order}}, run(M, S)),
    ?assertMatch({ok, #{final := {some, 5}}}, run(M#{consistency := <<"eventual">>}, S)),
    BadFinal = M#{abstract := fun(_, [_]) -> 6 end, consistency := <<"eventual">>},
    ?assertMatch({error, #{reason := no_consistent_order}}, run(BadFinal, S)).

failed_adapter_releases_peer_and_retains_failure_test() ->
    M0 = counter(false),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, _) -> error(broken_adapter) end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    S = spec("c", "", <<"(par (process (call add x (int 5)) (send c (var x)))
        (process (receive c y)))">>),
    ?assertMatch({error, #{reason := {raised, error, broken_adapter}}}, run(M, S)).

blocked_receive_reports_timeout_test() ->
    S = spec("c", "", <<"(par (process (receive c x)) (process (receive c y)))">>),
    ?assertMatch({error, #{reason := {raised, error, {lawspec, {scenario_io, {receive_timeout, _}}}}}},
        lawspec_beam_scenario:run(counter(false), S, 0, #{receive_timeout => 2})).

process_death_cancels_native_calls_and_hub_test() ->
    Owner = self(), M0 = counter(false),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, _) ->
        Owner ! {blocked, self()}, receive finish -> ls_unit end end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    S = spec("", "", <<"(par (process (call add _ (int 1))) (process (call add _ (int 2))))">>),
    {Root, RM} = spawn_monitor(fun() -> run(M, S) end),
    A = receive {blocked, P1} -> P1 after 1000 -> error(no_worker) end,
    B = receive {blocked, P2} -> P2 after 1000 -> error(no_worker) end,
    {monitored_by, Services} = process_info(Root, monitored_by),
    Monitors = [{P, monitor(process, P)} || P <- lists:usort([A, B | Services]), P =/= self()],
    exit(Root, kill), receive {'DOWN', RM, process, Root, killed} -> ok end,
    lists:foreach(fun({P, Ref}) -> receive {'DOWN', Ref, process, P, _} -> ok after 1000 -> error({leaked, P}) end end, Monitors).

shared_context_is_fresh_per_scenario_test() ->
    Owner = self(), M = (counter(false))#{context := fun(Body) ->
        Ref = make_ref(), Owner ! {opened, Ref}, try Body(Ref) after Owner ! {closed, Ref} end
    end},
    S = spec("", "", <<"(call add _ (int 5))">>),
    ?assertMatch({ok, _}, run(M, S)), ?assertMatch({ok, _}, run(M, S)),
    A = receive {opened, X} -> X end, receive {closed, A} -> ok end,
    B = receive {opened, Y} -> Y end, receive {closed, B} -> ok end, ?assertNotEqual(A, B).

network_schedule_cannot_silently_use_local_channels_test() ->
    ?assertMatch({error, #{reason := {raised, error, {lawspec, scenario_network_not_available}}}},
        lawspec_beam_scenario:run(counter(false), spec("", "", <<>>), 0, #{network => true})).

vectors(Path) ->
    {ok, Data} = file:read_file(Path), Entries = json:decode(Data),
    lists:foreach(fun(#{<<"spec">> := Spec, <<"seed">> := Seed, <<"cases">> := Cases}) ->
        Program = lawspec_beam_scenario:new(Spec),
        Actual = [#{<<"shake">> => Shake, <<"network">> => maps:get(network, Opts),
            <<"crash">> => maps:get(crash, Opts),
            <<"victim">> => case lawspec_beam_scenario:victim(Program, Shake) of
                none -> null; {Id, At} -> [Id, At] end} || {Shake, Opts} <- lawspec_beam_scenario:schedules(Seed, length(Cases))],
        ?assertEqual(Cases, Actual)
    end, Entries),
    io:format("~B scenario scheduling sequences matched the portable reference~n", [length(Entries)]).
