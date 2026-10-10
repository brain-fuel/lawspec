%% @doc Typed session conversations, moves and nested relays use actual
%% nodes, canonical frames and faulty delivery, with node-owned services.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_session_network_tests).
-include_lib("eunit/include/eunit.hrl").

spec(Id) -> #{id => Id, protocols => #{
    serve => [{'receive', {value, <<"(int Int32 _ _)">>}},
        {'receive', {value, <<"(int Int32 _ _)">>}}, {send, {value, <<"(int Int32 _ _)">>}}],
    passing => [{send, {session, serve}}],
    pick => [{'receive', {session, serve}}], pass_pick => [{send, {session, pick}}],
    give => [{send, {session, serve}}], pass_give => [{send, {session, give}}],
    data => [{send, {value, <<"(maybe (list (int Int32 _ _)))">>}}, {'receive', {value, <<"(unit)">>}}],
    stream => [{send, {value, <<"(int Int32 _ _)">>}}, {send, {value, <<"(int Int32 _ _)">>}}],
    unwired => [{send, {value, none}}], nonwire_child => [{send, {session, unwired}}]}}.
faults() -> #{seed => 918, loss => 0.15, duplicate => 0.25, delay => 0.001, record => true}.
with_nodes(Faults, Body) ->
    lawspec_beam_memory_network:with_network(Faults, fun(Net) ->
        Ns = [begin {ok, N} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, Name)), N
            end || Name <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>]],
        try Body(Net, Ns) after lists:foreach(fun lawspec_beam_node:stop/1, Ns) end
    end).
pair(Id, A, B, Name) ->
    First = lawspec_beam_session:listen(A, Name, spec(Id)),
    Second = lawspec_beam_session:dial(B, lawspec_beam_session:address(First), spec(Id)), {First, Second}.
sum(First) ->
    {A, F1} = lawspec_beam_session:receive_value(First),
    {B, F2} = lawspec_beam_session:receive_value(F1),
    _ = lawspec_beam_session:send(F2, A + B), ok.
ask(Second) ->
    S1 = lawspec_beam_session:send(Second, 17), S2 = lawspec_beam_session:send(S1, 25),
    {Answer, _} = lawspec_beam_session:receive_value(S2), Answer.
pass(End, A, B, Id, Name) ->
    {Give, Take} = pair(Id, A, B, Name), _ = lawspec_beam_session:send_end(Give, End),
    {Moved, _} = lawspec_beam_session:receive_end(Take), Moved.
pid({lawspec_session, Pid, _, _, _}) -> Pid.

typed_conversation_repairs_faulty_delivery_test_() ->
    {timeout, 10, fun() -> with_nodes(faults(), fun(Net, [A, B | _]) ->
        {First, Second} = pair(serve, A, B, <<"serve">>),
        Task = lawspec_beam_session_task:start(First, fun sum/1),
        ?assertEqual(42, ask(Second)), ?assertEqual(ok, lawspec_beam_session_task:join(Task)),
        ?assert(lists:any(fun(#{outcome := Outcome}) -> Outcome =:= lost end, lawspec_beam_memory_network:trace(Net)))
    end) end}.

onward_move_keeps_queued_values_after_old_nodes_close_test_() ->
    {timeout, 15, fun() -> with_nodes(faults(), fun(_, [A, B, C, D]) ->
        {First, Client} = pair(serve, A, C, <<"original">>),
        C1 = lawspec_beam_session:send(Client, 17), C2 = lawspec_beam_session:send(C1, 25),
        OnB = pass(First, A, B, passing, <<"to-b">>),
        ?assertException(error, {lawspec, {session, _}}, lawspec_beam_session:receive_value(First)),
        OnD = pass(OnB, B, D, passing, <<"to-d">>),
        ok = lawspec_beam_node:stop(A), ok = lawspec_beam_node:stop(B),
        Task = lawspec_beam_session_task:start(OnD, fun sum/1),
        {42, _} = lawspec_beam_session:receive_value(C2),
        ?assertEqual(ok, lawspec_beam_session_task:join(Task))
    end) end}.

local_end_is_relayed_on_its_node_test_() ->
    {timeout, 10, fun() -> with_nodes(faults(), fun(_, [A, B | _]) ->
        lawspec_beam_session:with_pair(spec(serve), fun(First, Client) ->
            Remote = pass(First, A, B, passing, <<"local">>),
            ?assertError({lawspec, {session, spent_end}}, lawspec_beam_session:receive_value(First)),
            Task = lawspec_beam_session_task:start(Remote, fun sum/1),
            ?assertEqual(42, ask(Client)), ?assertEqual(ok, lawspec_beam_session_task:join(Task))
        end)
    end) end}.

nested_local_delegation_is_relayed_recursively_test_() ->
    {timeout, 15, fun() -> with_nodes(faults(), fun(_, [A, B | _]) ->
        lawspec_beam_session:with_pair(spec(pick), fun(Pick, Offer) ->
            lawspec_beam_session:with_pair(spec(serve), fun(Server, Client) ->
                RemotePick = pass(Pick, A, B, pass_pick, <<"nested">>),
                _ = lawspec_beam_session:send_end(Offer, Server),
                {RemoteServer, _} = lawspec_beam_session:receive_end(RemotePick),
                Task = lawspec_beam_session_task:start(RemoteServer, fun sum/1),
                ?assertEqual(42, ask(Client)), ?assertEqual(ok, lawspec_beam_session_task:join(Task))
            end)
        end)
    end) end}.

relay_takes_a_network_end_back_to_the_local_queue_test_() ->
    {timeout, 15, fun() -> with_nodes(faults(), fun(_, [A, B, C | _]) ->
        lawspec_beam_session:with_pair(spec(give), fun(Give, Receive) ->
            RemoteGive = pass(Give, A, B, pass_give, <<"back">>),
            {Server, Client} = pair(serve, B, C, <<"returning">>),
            _ = lawspec_beam_session:send_end(RemoteGive, Server),
            {Here, _} = lawspec_beam_session:receive_end(Receive),
            ok = lawspec_beam_node:stop(B),
            Task = lawspec_beam_session_task:start(Here, fun sum/1),
            ?assertEqual(42, ask(Client)), ?assertEqual(ok, lawspec_beam_session_task:join(Task))
        end)
    end) end}.

canonical_optional_collection_and_unit_payloads_test() ->
    with_nodes(#{record => true}, fun(Net, [A, B | _]) ->
        {First, Second} = pair(data, A, B, <<"data">>),
        Value = {ls_data, <<"Maybe::Just">>, [[0, -7, 2147483647]]},
        F1 = lawspec_beam_session:send(First, Value),
        {Value, S1} = lawspec_beam_session:receive_value(Second),
        _ = lawspec_beam_session:send(S1, ls_unit),
        {ls_unit, _} = lawspec_beam_session:receive_value(F1),
        Bodies = [Body || Frame <- lawspec_beam_memory_network:recorded(Net),
            {ok, #{kind := <<"chan">>, payload := Payload}} <- [lawspec_beam_wire:read_frame(Frame)],
            {Sequence, _, <<0, Body/binary>>} <- [lawspec_beam_wire:read_channel(Payload)], Sequence >= 0],
        ?assert(lists:member(<<1, 3, 0, 13, 254, 255, 255, 255, 15>>, Bodies)),
        ?assert(lists:member(<<>>, Bodies))
    end).

nonwire_protocols_are_rejected_before_allocating_services_test() ->
    with_nodes(#{}, fun(_, [A | _]) ->
        Scope = maps:get(scope, sys:get_state(A)),
        Before = maps:get(workers, sys:get_state(Scope)),
        ?assertError({lawspec, {session, non_wire_payload}}, lawspec_beam_session:listen(A, <<"bad">>, spec(unwired))),
        ?assertError({lawspec, {session, non_wire_payload}}, lawspec_beam_session:listen(A, <<"bad">>, spec(nonwire_child))),
        ?assertEqual(Before, maps:get(workers, sys:get_state(Scope)))
    end).

abnormal_owner_exit_preserves_accepted_values_before_eof_test() ->
    with_nodes(#{}, fun(_, [A, B | _]) ->
        {First, Second} = pair(stream, A, B, <<"failure">>),
        ?assertError(probe, lawspec_beam_session:with_owned([First], fun() ->
            _ = lawspec_beam_session:send(First, 8), error(probe)
        end)),
        {8, S1} = lawspec_beam_session:receive_value(Second),
        ?assertException(error, {lawspec, {session, {peer_failed, _}}}, lawspec_beam_session:receive_value(S1))
    end).

killing_a_typed_coordinator_still_publishes_ordered_eof_test() ->
    with_nodes(#{}, fun(_, [A, B | _]) ->
        {First, Second} = pair(stream, A, B, <<"killed">>),
        _ = lawspec_beam_session:send(First, 9),
        Monitor = monitor(process, pid(First)), exit(pid(First), kill),
        receive {'DOWN', Monitor, process, _, killed} -> ok end,
        {9, S1} = lawspec_beam_session:receive_value(Second),
        %% This must be peer EOF, never the five-second reader timeout.
        ?assertError({lawspec, {session, {peer_failed, <<"the other end gave up the conversation">>}}},
            lawspec_beam_session:receive_value(S1))
    end).

failed_connection_releases_its_unpublished_endpoint_test() ->
    with_nodes(#{}, fun(_, [A | _]) ->
        ?assertException(error, {lawspec, _}, lawspec_beam_session:dial(A, <<"invalid">>, spec(serve))),
        until(fun() -> maps:get(entities, sys:get_state(A)) =:= #{} end)
    end).

malformed_payload_closes_the_typed_end_test() ->
    with_nodes(#{}, fun(_, [A, B | _]) ->
        {First, Second} = pair(data, A, B, <<"malformed">>),
        ok = lawspec_beam_endpoint:send(lawspec_beam_session:network_endpoint(First), <<2>>),
        ?assertException(error, {lawspec, {session, {peer_failed, {invalid_payload, _, _}}}},
            lawspec_beam_session:receive_value(Second))
    end).

node_close_joins_relays_and_session_services_test() ->
    with_nodes(#{}, fun(_, [A, B | _]) ->
        lawspec_beam_session:with_pair(spec(serve), fun(First, Client) ->
            Remote = pass(First, A, B, passing, <<"owned">>),
            Scope = maps:get(scope, sys:get_state(A)), Workers = maps:keys(maps:get(workers, sys:get_state(Scope))),
            ?assert(length(Workers) >= 3),
            ok = lawspec_beam_node:stop(A),
            ?assert(lists:all(fun(P) -> not is_process_alive(P) end, Workers)),
            ?assertException(error, {lawspec, {session, _}}, ask(Client)),
            ok = lawspec_beam_session:abandon(Remote),
            until(fun() -> not is_process_alive(pid(First)) end)
        end)
    end).

receive_and_failed_take_honor_deadlines_test() ->
    with_nodes(#{}, fun(Net, [A, B, C, D]) ->
        Short = (spec(serve))#{deadline => 75},
        First = lawspec_beam_session:listen(A, <<"silent">>, Short),
        ?assertException(error, {lawspec, {session, {peer_failed, receive_timeout}}}, lawspec_beam_session:receive_value(First)),
        Other = lawspec_beam_session:listen(C, <<"partitioned">>, Short),
        _ = lawspec_beam_session:dial(B, lawspec_beam_session:address(Other), Short),
        Give = lawspec_beam_session:listen(A, <<"giving">>, (spec(passing))#{deadline => 75}),
        Take = lawspec_beam_session:dial(D, lawspec_beam_session:address(Give), (spec(passing))#{deadline => 75}),
        ok = lawspec_beam_memory_network:partition(Net, [[<<"a">>, <<"d">>], [<<"b">>], [<<"c">>]]),
        _ = lawspec_beam_session:send_end(Give, Other),
        ?assertException(error, {lawspec, {session, {peer_failed, _}}}, lawspec_beam_session:receive_end(Take))
    end).

dead_reader_cancels_take_and_releases_the_acquired_session_test() ->
    with_nodes(#{}, fun(_, [A, B, C, D]) ->
        {First, _} = pair(serve, C, B, <<"held">>), Endpoint = lawspec_beam_session:network_endpoint(First),
        {Give, Take} = pair(passing, A, D, <<"take">>),
        _ = lawspec_beam_session:send_end(Give, First),
        ok = sys:suspend(Endpoint),
        {Reader, Monitor} = spawn_monitor(fun() ->
            lawspec_beam_session:with_owned([Take], fun() -> lawspec_beam_session:receive_end(Take) end)
        end),
        try
            Parent = pid(Take), Graph = maps:get(graph, sys:get_state(Parent)),
            Children = fun() -> [Child || {Child, P} <- maps:to_list(maps:get(parents, sys:get_state(Graph))), P =:= Parent] end,
            until(fun() -> Children() =/= [] end),
            [Acquired] = Children(),
            Jobs = maps:get(jobs, sys:get_state(Parent)), ?assertEqual(1, map_size(Jobs)),
            exit(Reader, kill), receive {'DOWN', Monitor, process, Reader, killed} -> ok end,
            until(fun() -> not is_process_alive(Parent) andalso not is_process_alive(Acquired) end)
        after sys:resume(Endpoint), exit(Reader, kill) end
    end).

cancelled_relay_setup_cannot_leave_a_worker_waiting_for_start_test() ->
    with_nodes(#{}, fun(_, [A, B | _]) ->
        {Give, _} = pair(passing, A, B, <<"cancel-setup">>),
        Test = self(),
        %% Pause precisely between describing an end and moving it. The
        %% stand-in serves only the two private setup messages; this makes
        %% the helper's cancellation boundary deterministic.
        Fake = spawn(fun() ->
            receive {'$gen_call', From, {{network_offer, serve}, _}} ->
                gen_server:reply(From, {ok, {local, spec(serve)}})
            end,
            receive {'$gen_call', _, {{transfer_to_relay, serve, Relay}, _}} ->
                Test ! {waiting_relay, Relay}, receive done -> ok end
            end
        end),
        FakeEnd = {lawspec_session, Fake, 0, make_ref(), 0},
        {Sender, Monitor} = spawn_monitor(fun() ->
            lawspec_beam_session:with_owned([Give], fun() -> lawspec_beam_session:send_end(Give, FakeEnd) end)
        end),
        try
            Relay = receive {waiting_relay, P} -> P after 1000 -> error(no_relay) end,
            exit(Sender, kill), receive {'DOWN', Monitor, process, Sender, killed} -> ok end,
            until(fun() -> not is_process_alive(Relay) end)
        after exit(Fake, kill), exit(Sender, kill) end
    end).

until(Body) -> until(Body, erlang:monotonic_time(millisecond) + 1000).
until(Body, Deadline) -> case Body() of
    true -> ok;
    false -> true = erlang:monotonic_time(millisecond) < Deadline, receive after 1 -> ok end, until(Body, Deadline)
end.
