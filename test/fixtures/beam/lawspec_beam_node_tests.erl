%% @doc Requests execute once across packet faults, and node shutdown joins
%% application workers. Persistent nodes outlive temporary creating callers.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_node_tests).
-include_lib("eunit/include/eunit.hrl").

with_nodes(Faults, Body) ->
    lawspec_beam_memory_network:with_network(Faults, fun(Net) ->
        A = node_at(Net, <<"a">>), B = node_at(Net, <<"b">>),
        try Body(Net, A, B) after lawspec_beam_node:stop(A), lawspec_beam_node:stop(B) end
    end).
node_at(Net, Name) ->
    {ok, Pid} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, Name)), Pid.
join({Pid, Ref}) -> receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 2000 -> exit(Pid, kill), error(worker_stuck) end.
until(Body) -> until(Body, erlang:monotonic_time(millisecond) + 1000).
until(Body, Deadline) -> case Body() of
    true -> ok;
    false -> true = erlang:monotonic_time(millisecond) < Deadline, receive after 1 -> ok end, until(Body, Deadline)
end.

requests_and_receipts_survive_real_packet_faults_test_() ->
    {timeout, 10, fun() -> with_nodes(#{seed => 9283, loss => 0.2, duplicate => 0.5, delay => 0.003, record => true}, fun(Net, A, B) ->
        Counter = atomics:new(1, []),
        Address = lawspec_beam_node:register_handler(B, <<"echo">>, fun(#{payload := Bytes}) ->
            atomics:add(Counter, 1, 1), {0, Bytes}
        end),
        Workers = [spawn_monitor(fun() ->
            ?assertEqual({0, <<I>>}, lawspec_beam_node:request(A, Address, <<"call">>, <<I>>, 3000))
        end) || I <- lists:seq(1, 30)],
        lists:foreach(fun join/1, Workers), ?assertEqual(30, atomics:get(Counter, 1)),
        ?assertEqual(0, map_size(maps:get(pending, sys:get_state(A)))),
        ?assertEqual(30, map_size(maps:get(seen, sys:get_state(B)))),
        ?assert(lists:any(fun(E) -> maps:get(outcome, E) =:= lost end, lawspec_beam_memory_network:trace(Net)))
    end) end}.

duplicates_while_handler_is_running_do_not_start_it_again_test() ->
    with_nodes(#{duplicate => 1}, fun(_, A, B) ->
        Owner = self(),
        Address = lawspec_beam_node:register_handler(B, <<"wait">>, fun(_) ->
            Owner ! {started, self()}, receive finish -> {0, <<"done">>} end
        end),
        {Ticket, _} = lawspec_beam_node:request_async(A, Address, <<"call">>, <<>>, 2000),
        Worker = receive {started, W} -> W after 1000 -> error(no_handler) end,
        %% The requester retries while the handler still owns this request.
        receive after 130 -> ok end,
        ?assertEqual(1, map_size(maps:get(jobs, sys:get_state(B)))),
        receive {started, _} -> error(duplicate_handler) after 0 -> ok end,
        Worker ! finish,
        receive {lawspec_reply, A, Ticket, Reply} -> ?assertEqual({ok, {0, <<"done">>}}, Reply)
        after 1000 -> error(no_reply) end
    end).

async_receiver_correlates_each_clock_with_its_request_test() ->
    with_nodes(#{seed => 53, duplicate => 0.5, loss => 0.1, delay => 0.02}, fun(_, A, B) ->
        Address = lawspec_beam_node:register_receiver(B, <<"mail">>, self()),
        Requests = [begin
            {Ticket, Identity} = lawspec_beam_node:request_async(A, Address, <<"mail">>, <<I>>, 2000),
            {Identity, Ticket, I}
        end || I <- lists:seq(1, 10)],
        Seen = [receive
            {lawspec_frame, B, #{source := Source, id := Identity, payload := <<I>>}} ->
                {Identity, _, I} = lists:keyfind(Identity, 1, Requests),
                ok = lawspec_beam_node:reply(B, Source, Identity, 0, <<I>>), I
        after 1000 -> error(no_mail) end || _ <- Requests],
        ?assertEqual(lists:seq(1, 10), lists:sort(Seen)),
        lists:foreach(fun({_, Ticket, I}) -> receive
            {lawspec_reply, A, Ticket, Result} -> ?assertEqual({ok, {0, <<I>>}}, Result)
        after 1000 -> error(no_receipt) end end, Requests),
        receive {lawspec_frame, B, _} -> error(duplicate_delivery) after 0 -> ok end
    end).

bad_handler_and_missing_entity_report_failures_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Address = lawspec_beam_node:register_handler(B, <<"broken">>, fun(_) -> error(broken_handler) end),
        ?assertMatch({1, _}, lawspec_beam_node:request(A, Address, <<"call">>, <<>>, 1000)),
        ?assertMatch({3, _}, lawspec_beam_node:request(A, <<"mem://b/missing">>, <<"call">>, <<>>, 1000)),
        ?assertEqual(<<"mem://b">>, lawspec_beam_node:address(B))
    end).

receiver_death_finishes_pending_receipt_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Owner = self(), {Receiver, RM} = spawn_monitor(fun() ->
            receive {lawspec_frame, B, _} -> Owner ! {received, self()}, receive finish -> ok end end
        end),
        Address = lawspec_beam_node:register_receiver(B, <<"mail">>, Receiver),
        {Ticket, _} = lawspec_beam_node:request_async(A, Address, <<"mail">>, <<>>, 2000),
        receive {received, Receiver} -> ok after 1000 -> error(no_mail) end,
        exit(Receiver, kill), receive {'DOWN', RM, process, Receiver, killed} -> ok end,
        receive {lawspec_reply, A, Ticket, Result} -> ?assertMatch({ok, {2, _}}, Result)
        after 1000 -> error(no_closed_reply) end
    end).

timeouts_and_cancellation_release_pending_slots_test() ->
    with_nodes(#{loss => 1}, fun(_, A, B) ->
        Address = lawspec_beam_node:register_handler(B, <<"never">>, fun(_) -> error(should_not_arrive) end),
        ?assertError({lawspec, {network, {unreachable, Address}}}, lawspec_beam_node:request(A, Address, <<"call">>, <<>>, 5)),
        {Ticket, _} = lawspec_beam_node:request_async(A, Address, <<"call">>, <<>>, 5000),
        ok = lawspec_beam_node:cancel(A, Ticket),
        Owner = self(), {Caller, CM} = spawn_monitor(fun() ->
            {T, _} = lawspec_beam_node:request_async(A, Address, <<"call">>, <<>>, 5000),
            Owner ! {pending, T}, receive finish -> ok end
        end),
        receive {pending, _} -> ok end, exit(Caller, kill), receive {'DOWN', CM, process, Caller, killed} -> ok end,
        until(fun() -> map_size(maps:get(pending, sys:get_state(A))) =:= 0 end),
        ?assertEqual(#{}, maps:get(pending_monitors, sys:get_state(A))),
        receive {lawspec_reply, A, Ticket, _} -> error(cancelled_reply) after 0 -> ok end
    end).

node_stop_joins_handlers_and_nested_async_workers_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Owner = self(), Address = lawspec_beam_node:register_handler(B, <<"wait">>, fun(_) ->
            process_flag(trap_exit, true), Owner ! {handler, self()},
            lawspec_beam_runtime:async_call(fun() ->
                process_flag(trap_exit, true), Owner ! {child, self()}, receive finish -> {0, <<>>} end
            end)
        end),
        {Ticket, _} = lawspec_beam_node:request_async(A, Address, <<"call">>, <<>>, 5000),
        Handler = receive {handler, H} -> H end, Child = receive {child, C} -> C end,
        ok = lawspec_beam_node:stop(B),
        ?assertNot(is_process_alive(Handler)), ?assertNot(is_process_alive(Child)),
        ok = lawspec_beam_node:cancel(A, Ticket)
    end).

killed_node_still_releases_trapping_handlers_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Owner = self(), Address = lawspec_beam_node:register_handler(B, <<"wait">>, fun(_) ->
            process_flag(trap_exit, true), Owner ! {handler, self()},
            lawspec_beam_runtime:async_call(fun() ->
                process_flag(trap_exit, true), Owner ! {child, self()}, receive finish -> {0, <<>>} end
            end)
        end),
        {Ticket, _} = lawspec_beam_node:request_async(A, Address, <<"call">>, <<>>, 5000),
        Handler = receive {handler, H} -> H end, Child = receive {child, C} -> C end,
        Monitors = [{P, monitor(process, P)} || P <- [B, Handler, Child]], exit(B, kill),
        lists:foreach(fun({P, M}) -> receive {'DOWN', M, process, P, _} -> ok after 1000 -> error(leaked_worker) end end, Monitors),
        ok = lawspec_beam_node:cancel(A, Ticket)
    end).

replacement_client_does_not_reuse_an_old_reply_test() ->
    with_nodes(#{}, fun(Net, A, B) ->
        Count = atomics:new(1, []), Address = lawspec_beam_node:register_handler(B, <<"count">>, fun(_) ->
            {0, <<(atomics:add_get(Count, 1, 1))>>}
        end),
        ?assertEqual({0, <<1>>}, lawspec_beam_node:request(A, Address, <<"call">>, <<>>, 1000)),
        lawspec_beam_node:stop(A), Replacement = node_at(Net, <<"a">>),
        try ?assertEqual({0, <<2>>}, lawspec_beam_node:request(Replacement, Address, <<"call">>, <<>>, 1000))
        after lawspec_beam_node:stop(Replacement) end
    end).

same_identity_with_different_content_is_rejected_test() ->
    with_nodes(#{record => true}, fun(Net, A, B) ->
        Owner = self(), Address = lawspec_beam_node:register_handler(B, <<"echo">>, fun(#{payload := P}) -> Owner ! invoked, {0, P} end),
        {Ticket, Identity} = lawspec_beam_node:request_async(A, Address, <<"call">>, <<"first">>, 1000),
        receive {lawspec_reply, A, Ticket, {ok, {0, <<"first">>}}} -> ok end,
        receive invoked -> ok end,
        ok = lawspec_beam_node:forward(A, #{to => Address, kind => <<"call">>, id => Identity, payload => <<"other">>}),
        until(fun() -> lists:any(fun(Bytes) ->
            case lawspec_beam_wire:read_frame(Bytes) of
                {ok, #{kind := <<"reply">>, id := Identity, payload := <<3, _/binary>>}} -> true;
                _ -> false
            end
        end, lawspec_beam_memory_network:recorded(Net)) end),
        receive invoked -> error(reexecuted_request) after 0 -> ok end,
        ?assertEqual(1, map_size(maps:get(seen, sys:get_state(B))))
    end).

only_the_registered_receiver_can_answer_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Owner = self(), {Receiver, RM} = spawn_monitor(fun() ->
            receive {lawspec_frame, B, #{source := Source, id := Id}} ->
                Owner ! {arrived, Source, Id},
                receive finish -> lawspec_beam_node:reply(B, Source, Id, 0, <<"real">>) end
            end
        end),
        Address = lawspec_beam_node:register_receiver(B, <<"mail">>, Receiver),
        {Ticket, Identity} = lawspec_beam_node:request_async(A, Address, <<"mail">>, <<>>, 1000),
        receive {arrived, Source, Identity} ->
            ?assertError({lawspec, {network, not_request_owner}}, lawspec_beam_node:reply(B, Source, Identity, 0, <<"fake">>))
        after 1000 -> error(no_request) end,
        Receiver ! finish,
        receive {lawspec_reply, A, Ticket, Result} -> ?assertEqual({ok, {0, <<"real">>}}, Result)
        after 1000 -> error(no_reply) end, join({Receiver, RM})
    end).

unregister_finishes_pending_requests_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Address = lawspec_beam_node:register_receiver(B, <<"mail">>, self()),
        {Ticket, _} = lawspec_beam_node:request_async(A, Address, <<"mail">>, <<>>, 1000),
        receive {lawspec_frame, B, _} -> ok after 1000 -> error(no_request) end,
        ok = lawspec_beam_node:unregister(B, <<"mail">>),
        receive {lawspec_reply, A, Ticket, Result} -> ?assertMatch({ok, {2, _}}, Result)
        after 1000 -> error(no_reply) end,
        ?assertEqual(Address, lawspec_beam_node:register_receiver(B, <<"mail">>, self()))
    end).

detached_node_survives_creator_and_scoped_node_follows_owner_test() ->
    lawspec_beam_memory_network:with_network(#{}, fun(Net) ->
        Owner = self(), Creator = spawn_monitor(fun() -> Owner ! {detached, node_at(Net, <<"detached">>)} end),
        Detached = receive {detached, D} -> D end, join(Creator),
        try ?assertEqual(<<"mem://detached">>, lawspec_beam_node:address(Detached)) after lawspec_beam_node:stop(Detached) end,
        {P, PM} = spawn_monitor(fun() ->
            lawspec_beam_node:with_node(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"owned">>), #{}, fun(N) ->
                Owner ! {owned, N}, receive finish -> ok end
            end)
        end),
        N = receive {owned, Node} -> Node end, NM = monitor(process, N),
        exit(P, kill), receive {'DOWN', PM, process, P, killed} -> ok end,
        receive {'DOWN', NM, process, N, normal} -> ok after 1000 -> error(owned_node_leaked) end
    end).

ordinary_transports_cannot_downgrade_to_cleartext_test() ->
    lawspec_beam_memory_network:with_network(#{}, fun(Net) ->
        ?assertEqual({error, secure_network_not_available}, lawspec_beam_node:start(lawspec_beam_memory_network:transport(Net, <<"secure">>)))
    end).
