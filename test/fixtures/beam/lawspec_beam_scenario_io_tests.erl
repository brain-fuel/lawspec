%% @doc Scenario ownership moves with delegated ends and reserved work.
%% Death, timeout and cancellation must not strand a peer or consume a value.
%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(lawspec_beam_scenario_io_tests).
-include_lib("eunit/include/eunit.hrl").

child(Id, Ends, Sends, Receives) -> #{id => Id, ends => Ends, sends => Sends, receives => Receives}.
end_at(Name, Side) -> {'end', Name, Side}.
with_io(Channels, Boxes, Body) -> lawspec_beam_scenario_io:with_io(Channels, Boxes, Body).
run(Hub, Id, Body) ->
    spawn_monitor(fun() ->
        ok = lawspec_beam_scenario_io:enter(Hub, Id),
        try Body() after lawspec_beam_scenario_io:leave(Hub, Id) end
    end).
join({Pid, Monitor}) -> receive {'DOWN', Monitor, process, Pid, normal} -> ok;
    {'DOWN', Monitor, process, Pid, Reason} -> error({worker_failed, Reason})
    after 1000 -> error(worker_stuck) end.
kill({Pid, Monitor}) -> exit(Pid, kill), receive {'DOWN', Monitor, process, Pid, killed} -> ok after 1000 -> error(worker_stuck) end.
ready(Ref) -> receive {ready, Ref} -> ok after 1000 -> error(worker_not_ready) end.

fifo_values_and_clocks_survive_sender_exit_test() ->
    with_io([c], #{}, fun(H) ->
        C0 = end_at(c, 0), C1 = end_at(c, 1),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C0], #{}, [])]),
        W = run(H, 1, fun() -> lists:foreach(fun(N) ->
            ok = lawspec_beam_scenario_io:send(H, 1, C0, N, #{1 => N})
        end, lists:seq(1, 20)) end),
        join(W),
        lists:foreach(fun(N) -> ?assertEqual({value, N, #{1 => N}},
            lawspec_beam_scenario_io:receive_value(H, root, C1)) end, lists:seq(1, 20)),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, C1)),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, C1))
    end).

queued_delegation_outlives_sender_test() ->
    with_io([c, r], #{}, fun(H) ->
        C0 = end_at(c, 0), C1 = end_at(c, 1), R0 = end_at(r, 0), R1 = end_at(r, 1),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C0, R0], #{}, [])]),
        W = run(H, 1, fun() -> lawspec_beam_scenario_io:send(H, 1, C0,
            {lawspec_scenario_end, r, 0}, #{1 => 1}) end), join(W),
        ?assertEqual({value, {lawspec_scenario_end, r, 0}, #{1 => 1}},
            lawspec_beam_scenario_io:receive_value(H, root, C1)),
        ok = lawspec_beam_scenario_io:send(H, root, R0, 42, #{root => 1}),
        ?assertEqual({value, 42, #{root => 1}}, lawspec_beam_scenario_io:receive_value(H, root, R1))
    end).

stranded_delegated_ends_close_on_receiver_death_test() ->
    with_io([c, r], #{}, fun(H) ->
        Owner = self(), Ref = make_ref(),
        C0 = end_at(c, 0), C1 = end_at(c, 1), R0 = end_at(r, 0), R1 = end_at(r, 1),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C1], #{}, [])]),
        W = run(H, 1, fun() -> Owner ! {ready, Ref}, receive finish -> ok end end), ready(Ref),
        ok = lawspec_beam_scenario_io:send(H, root, C0, {lawspec_scenario_end, r, 0}, #{}),
        ?assertError({lawspec, {scenario_io, {not_endpoint_owner, R0}}},
            lawspec_beam_scenario_io:send(H, root, R0, 1, #{})),
        kill(W), ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, R1))
    end).

delegation_to_already_failed_receiver_is_released_test() ->
    with_io([c, r], #{}, fun(H) ->
        C0 = end_at(c, 0), C1 = end_at(c, 1),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C1], #{}, [])]),
        join(run(H, 1, fun() -> ok end)),
        ok = lawspec_beam_scenario_io:send(H, root, C0, {lawspec_scenario_end, r, 0}, #{}),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, end_at(r, 1)))
    end).

closing_delegation_cycles_terminates_test() ->
    with_io([a, b], #{}, fun(H) ->
        %% Each abandoned incoming queue owns the other channel's end.
        ok = lawspec_beam_scenario_io:send(H, root, end_at(a, 0), {lawspec_scenario_end, b, 1}, #{}),
        ok = lawspec_beam_scenario_io:send(H, root, end_at(b, 0), {lawspec_scenario_end, a, 1}, #{}),
        ok = lawspec_beam_scenario_io:leave(H, root),
        Queues = maps:get(queues, sys:get_state(H)),
        ?assert(lists:all(fun(#{closed := Closed}) -> Closed end, maps:values(Queues)))
    end).

mailbox_sends_keep_their_own_clock_test() ->
    with_io([], #{m => 100}, fun(H) ->
        Specs = [child(I, [], #{m => 5}, []) || I <- lists:seq(1, 20)],
        ok = lawspec_beam_scenario_io:fork(H, root, Specs),
        Workers = [run(H, I, fun() -> lists:foreach(fun(N) ->
            ok = lawspec_beam_scenario_io:send(H, I, {mailbox, m}, {I, N}, #{I => N})
        end, lists:seq(1, 5)) end) || I <- lists:seq(1, 20)],
        Values = [lawspec_beam_scenario_io:receive_value(H, root, {mailbox, m}) || _ <- lists:seq(1, 100)],
        ?assertEqual(lists:sort([{value, {I, N}, #{I => N}} || I <- lists:seq(1, 20), N <- lists:seq(1, 5)]),
            lists:sort(Values)),
        lists:foreach(fun join/1, Workers),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, m}))
    end).

death_releases_unstarted_descendant_sends_test() ->
    with_io([], #{m => 3}, fun(H) ->
        Owner = self(), Ref = make_ref(),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [], #{m => 3}, [])]),
        W = run(H, 1, fun() ->
            ok = lawspec_beam_scenario_io:send(H, 1, {mailbox, m}, 11, #{1 => 1}),
            %% The remaining two sends belong to a nested par never started.
            Owner ! {ready, Ref}, receive finish -> ok end
        end), ready(Ref), kill(W),
        ?assertEqual({value, 11, #{1 => 1}}, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, m})),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, m}))
    end).

death_releases_reserved_but_unclaimed_children_test() ->
    with_io([c], #{m => 2}, fun(H) ->
        Owner = self(), Ref = make_ref(), C0 = end_at(c, 0),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C0], #{m => 2}, [])]),
        W = run(H, 1, fun() ->
            ok = lawspec_beam_scenario_io:fork(H, 1, [child(2, [C0], #{m => 2}, [])]),
            Owner ! {ready, Ref}, receive finish -> ok end
        end), ready(Ref), kill(W),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, m})),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, end_at(c, 1))),
        ?assertError({lawspec, {scenario_io, {cannot_enter, 2}}}, lawspec_beam_scenario_io:enter(H, 2))
    end).

dead_mailbox_receiver_releases_queued_and_later_ends_test() ->
    with_io([a, b], #{m => 2}, fun(H) ->
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [], #{}, [m])]),
        ok = lawspec_beam_scenario_io:send(H, root, {mailbox, m}, {lawspec_scenario_end, a, 0}, #{}),
        join(run(H, 1, fun() -> ok end)),
        ok = lawspec_beam_scenario_io:send(H, root, {mailbox, m}, {lawspec_scenario_end, b, 0}, #{}),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, end_at(a, 1))),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, end_at(b, 1)))
    end).

timed_out_receive_cannot_steal_later_message_test() ->
    with_io([c], #{}, fun(H) ->
        C0 = end_at(c, 0), C1 = end_at(c, 1),
        ?assertError({lawspec, {scenario_io, {receive_timeout, C1}}},
            lawspec_beam_scenario_io:receive_value(H, root, C1, 1)),
        ok = lawspec_beam_scenario_io:send(H, root, C0, 42, #{}),
        ?assertEqual({value, 42, #{}}, lawspec_beam_scenario_io:receive_value(H, root, C1, 0))
    end).

invalid_fork_is_atomic_test() ->
    with_io([c], #{m => 1}, fun(H) ->
        C0 = end_at(c, 0), C1 = end_at(c, 1), Before = sys:get_state(H),
        ?assertError({lawspec, {scenario_io, {send_quota, m}}}, lawspec_beam_scenario_io:fork(H, root,
            [child(1, [C0], #{m => 1}, []), child(2, [C1], #{m => 1}, [])])),
        ?assertEqual(Before, sys:get_state(H)),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C0], #{m => 1}, [])]),
        join(run(H, 1, fun() -> ok end)),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, m}))
    end).

caller_cannot_impersonate_another_process_test() ->
    with_io([c], #{}, fun(H) ->
        C0 = end_at(c, 0),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [C0], #{}, [])]),
        ?assertError({lawspec, {scenario_io, {not_process_owner, 1}}}, lawspec_beam_scenario_io:send(H, 1, C0, 1, #{})),
        ?assertError({lawspec, {scenario_io, {not_endpoint_owner, C0}}}, lawspec_beam_scenario_io:send(H, root, C0, 1, #{}))
    end).

owner_death_stops_hub_and_wakes_pending_callers_test() ->
    Owner = self(), Ref = make_ref(),
    Parent = spawn_monitor(fun() ->
        {ok, H} = lawspec_beam_scenario_io:start([c], #{}),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [end_at(c, 1)], #{}, [])]),
        Owner ! {hub, Ref, H}, receive finish -> ok end
    end),
    H = receive {hub, Ref, Hub} -> Hub after 1000 -> error(no_hub) end, HM = monitor(process, H),
    {Pid, WM} = spawn_monitor(fun() ->
        ok = lawspec_beam_scenario_io:enter(H, 1), Owner ! {ready, Ref},
        try lawspec_beam_scenario_io:receive_value(H, 1, end_at(c, 1)) of _ -> error(unexpected_value)
        catch exit:{normal, _} -> ok; exit:{noproc, _} -> ok end
    end), ready(Ref), kill(Parent), join({Pid, WM}),
    receive {'DOWN', HM, process, H, normal} -> ok after 1000 -> error(hub_leaked) end.

with_io_stops_on_exception_test() ->
    Owner = self(),
    ?assertError(broken, with_io([], #{}, fun(H) -> Owner ! {hub, H}, error(broken) end)),
    H = receive {hub, Hub} -> Hub end, ?assertNot(is_process_alive(H)).
