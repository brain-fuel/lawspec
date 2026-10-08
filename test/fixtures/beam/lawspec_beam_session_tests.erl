%% @doc Session progress, transfer and failure use real concurrent workers.
%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(lawspec_beam_session_tests).
-include_lib("eunit/include/eunit.hrl").

spec(Id) -> #{id => Id, protocols => #{
    serve => [{'receive', {value, none}}, {'receive', {value, none}}, {send, {value, none}}],
    hire => [{send, {session, serve}}],
    stream => [{send, {value, none}}, {send, {value, none}}],
    recursive => [{'receive', {session, recursive}}], empty => []}}.
with_pair(Id, Body) -> lawspec_beam_session:with_pair(spec(Id), Body).
run(Ends, Body) -> lawspec_beam_session:with_owned(Ends, Body).
sum(Server) ->
    {A, S1} = lawspec_beam_session:receive_value(Server),
    {B, S2} = lawspec_beam_session:receive_value(S1),
    _ = lawspec_beam_session:send(S2, A + B), ok.
ask(Client, A, B) ->
    C1 = lawspec_beam_session:send(Client, A), C2 = lawspec_beam_session:send(C1, B),
    {Value, _} = lawspec_beam_session:receive_value(C2), Value.
pid({lawspec_session, Pid, _, _, _}) -> Pid.

typed_steps_complete_and_release_channel_test() ->
    with_pair(serve, fun(Server, Client) ->
        ?assertEqual([ok, 42], lawspec_beam_runtime:concurrently([
            fun() -> run([Server], fun() -> sum(Server) end) end,
            fun() -> run([Client], fun() -> ask(Client, 17, 25) end) end])),
        until(fun() -> not is_process_alive(pid(Server)) end)
    end).

empty_protocol_allocates_no_lingering_channel_test() ->
    with_pair(empty, fun(First, Second) ->
        ?assertEqual(pid(First), pid(Second)), ?assertNot(is_process_alive(pid(First)))
    end).

used_handle_cannot_repeat_step_test() ->
    with_pair(stream, fun(First, Second) ->
        F1 = lawspec_beam_session:send(First, one),
        ?assertError({lawspec, {session, spent_end}}, lawspec_beam_session:send(First, lost)),
        _ = lawspec_beam_session:send(F1, two),
        {one, S1} = lawspec_beam_session:receive_value(Second),
        {two, _} = lawspec_beam_session:receive_value(S1)
    end).

wrong_operation_does_not_consume_handle_test() ->
    with_pair(stream, fun(First, Second) ->
        ?assertError({lawspec, {session, wrong_step}}, lawspec_beam_session:receive_value(First)),
        _ = lawspec_beam_session:send(First, accepted),
        {accepted, _} = lawspec_beam_session:receive_value(Second)
    end).

competing_copies_admit_only_one_send_test() ->
    with_pair(stream, fun(First, Second) ->
        Results = lawspec_beam_runtime:concurrently([fun() ->
            try {ok, lawspec_beam_session:send(First, I)} catch error:{lawspec, {session, spent_end}} -> spent end
        end || I <- lists:seq(1, 20)]),
        ?assertEqual(19, length([spent || spent <- Results])),
        [{ok, Next}] = [R || {ok, _} = R <- Results],
        _ = lawspec_beam_session:send(Next, last),
        {Winner, S1} = lawspec_beam_session:receive_value(Second), ?assert(Winner >= 1 andalso Winner =< 20),
        {last, _} = lawspec_beam_session:receive_value(S1)
    end).

failed_sender_drains_accepted_values_before_eof_test() ->
    with_pair(stream, fun(First, Second) ->
        ?assertError(probe, lawspec_beam_runtime:async_call(fun() -> run([First], fun() ->
            _ = lawspec_beam_session:send(First, kept), error(probe)
        end) end)),
        {kept, S1} = lawspec_beam_session:receive_value(Second),
        ?assertError({lawspec, {session, peer_failed}}, lawspec_beam_session:receive_value(S1))
    end).

killed_receiver_wakes_its_peer_test() ->
    with_pair(serve, fun(Server, Client) ->
        {Worker, Ref} = spawn_monitor(fun() -> run([Server], fun() -> lawspec_beam_session:receive_value(Server) end) end),
        until(fun() -> maps:get(reader, end_state(Server)) =/= none end),
        exit(Worker, kill), receive {'DOWN', Ref, process, Worker, killed} -> ok end,
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2))
    end).

successful_async_return_keeps_next_end_valid_test() ->
    with_pair(stream, fun(First, Second) ->
        Next = lawspec_beam_runtime:async_call(fun() -> run([First], fun() -> lawspec_beam_session:send(First, one) end) end),
        _ = lawspec_beam_session:send(Next, two),
        {one, S1} = lawspec_beam_session:receive_value(Second), {two, _} = lawspec_beam_session:receive_value(S1)
    end).

delegation_invalidates_sender_and_survives_sender_failure_test() ->
    with_pair(serve, fun(Server, Client) -> with_pair(hire, fun(Boss, Manager) ->
        ?assertError(probe, lawspec_beam_runtime:async_call(fun() -> run([Boss, Server], fun() ->
            _ = lawspec_beam_session:send_end(Boss, Server), error(probe)
        end) end)),
        ?assertError({lawspec, {session, spent_end}}, lawspec_beam_session:receive_value(Server)),
        ?assertEqual([ok, 42], lawspec_beam_runtime:concurrently([
            fun() -> run([Manager], fun() -> {Hired, _} = lawspec_beam_session:receive_end(Manager), sum(Hired) end) end,
            fun() -> run([Client], fun() -> ask(Client, 17, 25) end) end]))
    end) end).

delegated_end_is_cleaned_if_receiver_abandons_queue_test() ->
    with_pair(serve, fun(Server, Client) -> with_pair(hire, fun(Boss, Manager) ->
        _ = lawspec_beam_session:send_end(Boss, Server),
        ok = lawspec_beam_session:abandon(Manager),
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2))
    end) end).

delegated_end_is_cleaned_if_queue_is_killed_test() ->
    with_pair(serve, fun(Server, Client) -> with_pair(hire, fun(Boss, _) ->
        _ = lawspec_beam_session:send_end(Boss, Server),
        exit(pid(Boss), kill),
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2))
    end) end).

newly_received_ends_are_owned_by_the_receiving_body_test() ->
    with_pair(serve, fun(Server, Client) -> with_pair(hire, fun(Boss, Manager) ->
        _ = lawspec_beam_session:send_end(Boss, Server),
        ?assertError(probe, run([Manager], fun() ->
            {_Hired, _} = lawspec_beam_session:receive_end(Manager), error(probe)
        end)),
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2))
    end) end).

scope_owner_death_closes_original_ends_test() ->
    Parent = self(), {Creator, Ref} = spawn_monitor(fun() -> with_pair(serve, fun(Server, Client) ->
        Parent ! {pair, Server, Client}, receive wait -> ok end
    end) end),
    {Server, Client} = receive {pair, A, B} -> {A, B} end,
    ok = lawspec_beam_session:claim(Server),
    Monitor = monitor(process, pid(Server)), exit(Creator, kill),
    receive {'DOWN', Ref, process, Creator, killed} -> ok end,
    receive {'DOWN', Monitor, process, _, normal} -> ok after 1000 -> error(leaked_channel) end,
    ?assertError({lawspec, {session, closed}}, lawspec_beam_session:send(Client, 1)).

new_channels_created_in_a_failed_body_are_cleaned_test() ->
    Parent = self(),
    ?assertError(probe, run([], fun() ->
        {First, _} = lawspec_beam_session:open(spec(stream)), Parent ! {created, pid(First)}, error(probe)
    end)),
    Channel = receive {created, P} -> P end,
    until(fun() -> not is_process_alive(Channel) end).

unfinished_transfer_precedes_sender_eof_test() ->
    with_pair(serve, fun(Server, Client) -> with_pair(hire, fun(Boss, Manager) ->
        ok = sys:suspend(pid(Server)),
        {Sender, Ref} = spawn_monitor(fun() -> run([Boss], fun() -> lawspec_beam_session:send_end(Boss, Server) end) end),
        try
            until(fun() -> maps:get(sending, end_state(Boss)) =/= none end),
            exit(Sender, kill), receive {'DOWN', Ref, process, Sender, killed} -> ok end,
            Parent = self(), {Receiver, ReceiverRef} = spawn_monitor(fun() -> run([Manager], fun() ->
                {Hired, _} = lawspec_beam_session:receive_end(Manager), Parent ! received, sum(Hired)
            end) end),
            until(fun() -> maps:get(reader, end_state(Manager)) =/= none end),
            receive received -> error(transfer_not_waited) after 0 -> ok end,
            ok = sys:resume(pid(Server)),
            ?assertEqual(42, ask(Client, 17, 25)),
            receive received -> ok after 1000 -> error(transfer_missing) end,
            receive {'DOWN', ReceiverRef, process, Receiver, normal} -> ok after 1000 -> error(receiver_failed) end
        after try sys:resume(pid(Server)) catch _:_ -> ok end end
    end) end).

closing_both_ends_joins_a_blocked_transfer_helper_test() ->
    with_pair(serve, fun(Server, _) ->
        Parent = self(), ok = sys:suspend(pid(Server)),
        Watchdog = spawn(fun() -> receive cancel -> ok after 1500 ->
            Parent ! watchdog_resumed, sys:resume(pid(Server)) end end),
        try
            with_pair(hire, fun(Boss, _) ->
                {Sender, Ref} = spawn_monitor(fun() ->
                    try lawspec_beam_session:send_end(Boss, Server)
                    catch error:{lawspec, {session, _}} -> ok end
                end),
                until(fun() -> maps:get(sending, end_state(Boss)) =/= none end),
                Parent ! {pending, pid(Boss), Sender, Ref}
            end),
            receive {pending, Channel, Sender, Ref} ->
                ?assertNot(is_process_alive(Channel)),
                receive {'DOWN', Ref, process, Sender, normal} -> ok after 1000 -> error(transfer_not_joined) end
            end,
            receive watchdog_resumed -> error(cleanup_waited_for_suspended_peer) after 0 -> ok end
        after Watchdog ! cancel, try sys:resume(pid(Server)) catch _:_ -> ok end end
    end).

received_end_still_works_after_parent_scope_finishes_test() ->
    with_pair(serve, fun(Server, Client) ->
        Hired = with_pair(hire, fun(Boss, Manager) ->
            _ = lawspec_beam_session:send_end(Boss, Server),
            {End, _} = lawspec_beam_session:receive_end(Manager), End
        end),
        ?assertEqual([ok, 42], lawspec_beam_runtime:concurrently([
            fun() -> run([Hired], fun() -> sum(Hired) end) end,
            fun() -> run([Client], fun() -> ask(Client, 17, 25) end) end]))
    end).

abandoning_recursive_custody_cycles_releases_both_channels_test() ->
    with_pair(recursive, fun(A, AOther) -> with_pair(recursive, fun(B, BOther) ->
        _ = lawspec_beam_session:send_end(AOther, B),
        ?assertError({lawspec, {session, cyclic_delegation}}, lawspec_beam_session:send_end(BOther, A))
    end) end).

concurrent_recursive_transfers_cannot_create_a_custody_cycle_test() ->
    with_pair(recursive, fun(A, AOther) -> with_pair(recursive, fun(B, BOther) ->
        Results = lawspec_beam_runtime:concurrently([fun() ->
            try {ok, lawspec_beam_session:send_end(Sender, Value)}
            catch error:{lawspec, {session, cyclic_delegation}} -> cycle end
        end || {Sender, Value} <- [{AOther, B}, {BOther, A}]]),
        ?assertEqual(1, length([cycle || cycle <- Results])),
        ?assertEqual(1, length([ok || {ok, _} <- Results]))
    end) end).

losing_custody_graph_stops_registered_channels_test() ->
    with_pair(stream, fun(First, _) ->
        Channel = pid(First), Ref = monitor(process, Channel),
        Graph = maps:get(graph, sys:get_state(Channel)), exit(Graph, kill),
        receive {'DOWN', Ref, process, Channel, _} -> ok after 1000 -> error(channel_outlived_graph) end,
        ?assertError({lawspec, {session, closed}}, lawspec_beam_session:send(First, bad))
    end).

only_unused_first_ends_can_be_delegated_test() ->
    with_pair(serve, fun(Server, Client) -> with_pair(hire, fun(Boss, _) ->
        ?assertError({lawspec, {session, not_an_unused_first_end}}, lawspec_beam_session:send_end(Boss, Client)),
        ?assertError({lawspec, {session, cyclic_delegation}}, lawspec_beam_session:send_end(Boss, Boss)),
        ?assert(is_process_alive(pid(Server)))
    end) end).

different_protocol_transfer_fails_without_spending_the_offered_end_test() ->
    with_pair(stream, fun(Offered, Receiver) -> with_pair(hire, fun(Boss, Manager) ->
        ?assertError({lawspec, {session, different_protocol}}, lawspec_beam_session:send_end(Boss, Offered)),
        _ = lawspec_beam_session:send(Offered, still_valid),
        {still_valid, _} = lawspec_beam_session:receive_value(Receiver),
        ?assertError({lawspec, {session, peer_failed}}, lawspec_beam_session:receive_end(Manager))
    end) end).

native_task_moves_argument_and_joins_result_test() ->
    with_pair(serve, fun(Server, Client) ->
        Task = lawspec_beam_session_task:start(Server, fun sum/1),
        ?assertError({lawspec, {session, spent_end}}, lawspec_beam_session:receive_value(Server)),
        ?assertEqual(42, ask(Client, 17, 25)),
        ?assertEqual(ok, lawspec_beam_session_task:join(Task)),
        ?assertNot(is_process_alive(Task))
    end).

native_task_failure_before_first_step_abandons_argument_test() ->
    with_pair(serve, fun(Server, Client) ->
        Task = lawspec_beam_session_task:start(Server, fun(_) -> error(task_probe) end),
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2)),
        ?assertError(task_probe, lawspec_beam_session_task:join(Task))
    end).

native_task_returns_partial_end_without_abandoning_it_test() ->
    with_pair(stream, fun(First, Second) ->
        Task = lawspec_beam_session_task:start(First, fun(End) -> lawspec_beam_session:send(End, one) end),
        Next = lawspec_beam_session_task:join(Task), _ = lawspec_beam_session:send(Next, two),
        {one, S1} = lawspec_beam_session:receive_value(Second), {two, _} = lawspec_beam_session:receive_value(S1)
    end).

native_task_cancellation_joins_blocked_worker_test() ->
    with_pair(serve, fun(Server, Client) ->
        Task = lawspec_beam_session_task:start(Server, fun sum/1),
        Worker = maps:get(worker, sys:get_state(Task)),
        ok = lawspec_beam_session_task:stop(Task), ?assertNot(is_process_alive(Worker)),
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2))
    end).

native_task_cancellation_joins_nested_async_workers_test() ->
    with_pair(serve, fun(Server, _) ->
        Parent = self(), Task = lawspec_beam_session_task:start(Server, fun(_) ->
            lawspec_beam_runtime:async_call(fun() ->
                lawspec_beam_runtime:concurrently([fun() -> Parent ! {nested, self()}, receive wait -> ok end end || _ <- [1,2]])
            end)
        end),
        Nested = [receive {nested, Pid} -> Pid after 1000 -> error(no_nested_worker) end || _ <- [1,2]],
        ok = lawspec_beam_session_task:stop(Task),
        [?assertNot(is_process_alive(Pid)) || Pid <- Nested]
    end).

native_task_owner_death_cancels_worker_test() ->
    with_pair(serve, fun(Server, Client) ->
        Parent = self(), {Creator, Ref} = spawn_monitor(fun() ->
            Task = lawspec_beam_session_task:start(Server, fun sum/1), Parent ! {task, Task}, receive wait -> ok end
        end),
        Task = receive {task, T} -> T end, TaskRef = monitor(process, Task),
        Worker = maps:get(worker, sys:get_state(Task)),
        exit(Creator, kill), receive {'DOWN', Ref, process, Creator, killed} -> ok end,
        receive {'DOWN', TaskRef, process, Task, normal} -> ok after 1000 -> error(task_leaked) end,
        ?assertNot(is_process_alive(Worker)),
        ?assertException(error, {lawspec, {session, _}}, ask(Client, 1, 2))
    end).

native_task_preserves_context_and_exception_class_test() ->
    with_pair(stream, fun(First, _) ->
        Key = {lawspec_beam_workflow, runtime}, Previous = put(Key, probe_context),
        try
            Task = lawspec_beam_session_task:start(First, fun(_) ->
                ?assertEqual(probe_context, get(Key)), throw(original_throw)
            end),
            ?assertThrow(original_throw, lawspec_beam_session_task:join(Task))
        after case Previous of undefined -> erase(Key); _ -> put(Key, Previous) end end
    end).

channel_and_task_services_are_released_test() ->
    until(fun() -> whereis(lawspec_beam_session_ownership) =:= undefined end),
    Leaked = [P || P <- processes(), P =/= self(),
        {dictionary, Entries} <- [process_info(P, dictionary)],
        {'$initial_call', {Module, _, _}} <- Entries,
        lists:member(Module, [lawspec_beam_session, lawspec_beam_session_task, lawspec_beam_session_ownership])],
    ?assertEqual([], Leaked).

end_state({lawspec_session, Pid, Side, _, _}) -> maps:get(Side, maps:get(ends, sys:get_state(Pid))).
until(Predicate) -> until(Predicate, erlang:monotonic_time(millisecond) + 2000).
until(Predicate, Deadline) -> case Predicate() of
    true -> ok;
    false -> ?assert(erlang:monotonic_time(millisecond) < Deadline), receive after 1 -> until(Predicate, Deadline) end
end.
