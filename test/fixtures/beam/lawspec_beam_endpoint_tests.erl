%% @doc Real endpoint services own retries, waiters and handoff state.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_endpoint_tests).
-include_lib("eunit/include/eunit.hrl").

with_ends(Faults, Options, Body) ->
    lawspec_beam_memory_network:with_network(Faults, fun(Net) ->
        Nodes = [begin
            {ok, N} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, Name)), N
        end || Name <- [<<"a">>, <<"b">>, <<"c">>]],
        try
            [A, B, C] = [begin {ok, E} = lawspec_beam_endpoint:start(N, <<"end">>, Options), E end || N <- Nodes],
            ok = lawspec_beam_endpoint:connect(B, lawspec_beam_endpoint:address(A)),
            Body(Net, Nodes, A, B, C)
        after lists:foreach(fun lawspec_beam_node:stop/1, Nodes) end
    end).
values(E, N) -> [begin {value, V} = lawspec_beam_endpoint:receive_body(E, 2000), V end || _ <- lists:seq(1, N)].
faults() -> #{seed => 723, loss => 0.2, duplicate => 0.4, delay => 0.003, record => true}.

reliable_services_keep_both_directions_ordered_test_() ->
    {timeout, 10, fun() -> with_ends(faults(), #{}, fun(Net, _, A, B, _) ->
        lists:foreach(fun(I) ->
            ok = lawspec_beam_endpoint:send(A, <<I>>), ok = lawspec_beam_endpoint:send(B, <<(255 - I)>>)
        end, lists:seq(1, 60)),
        ok = lawspec_beam_endpoint:abandon(A), ok = lawspec_beam_endpoint:abandon(B),
        ?assertEqual([<<I>> || I <- lists:seq(1, 60)], values(B, 60)),
        ?assertEqual([<<(255 - I)>> || I <- lists:seq(1, 60)], values(A, 60)),
        ?assertMatch({error, <<"the other end gave up", _/binary>>}, lawspec_beam_endpoint:receive_body(A, 1000)),
        ?assertMatch({error, <<"the other end gave up", _/binary>>}, lawspec_beam_endpoint:receive_body(B, 1000)),
        ?assert(lists:any(fun(#{outcome := O}) -> O =:= lost end, lawspec_beam_memory_network:trace(Net)))
    end) end}.

handoff_keeps_inflight_values_after_old_node_stops_test_() ->
    {timeout, 10, fun() -> with_ends(faults(), #{}, fun(_, [Old | _], A, B, C) ->
        lists:foreach(fun(I) -> ok = lawspec_beam_endpoint:send(B, <<I>>) end, lists:seq(1, 15)),
        Address = lawspec_beam_endpoint:offer(A),
        ?assertEqual(Address, lawspec_beam_endpoint:offer(A)),
        ok = lawspec_beam_endpoint:take(C, Address),
        ok = lawspec_beam_node:stop(Old), ?assertNot(is_process_alive(A)),
        lists:foreach(fun(I) -> ok = lawspec_beam_endpoint:send(B, <<I>>) end, lists:seq(16, 50)),
        ok = lawspec_beam_endpoint:abandon(B),
        ?assertEqual([<<I>> || I <- lists:seq(1, 50)], values(C, 50)),
        ?assertMatch({error, _}, lawspec_beam_endpoint:receive_body(C, 1000))
    end) end}.

timed_out_or_cancelled_reads_cannot_steal_later_values_test() ->
    with_ends(#{}, #{}, fun(_, _, A, B, _) ->
        ?assertEqual({error, receive_timeout}, lawspec_beam_endpoint:receive_body(A, 1)),
        Ticket = lawspec_beam_endpoint:receive_async(A, infinity),
        ?assertError({lawspec, {channel, already_receiving}}, lawspec_beam_endpoint:receive_body(A, 1)),
        ok = lawspec_beam_endpoint:cancel(A, Ticket),
        ok = lawspec_beam_endpoint:send(B, <<"kept">>),
        ?assertEqual([<<"kept">>], values(A, 1)),
        receive {lawspec_channel, A, Ticket, _} -> error(stale_read) after 0 -> ok end
    end).

reader_death_releases_the_receive_slot_test() ->
    with_ends(#{}, #{}, fun(_, _, A, B, _) ->
        Owner = self(), {Pid, Monitor} = spawn_monitor(fun() ->
            _ = lawspec_beam_endpoint:receive_async(A, infinity), Owner ! pending, receive finish -> ok end
        end),
        receive pending -> ok end, exit(Pid, kill), receive {'DOWN', Monitor, process, Pid, killed} -> ok end,
        until(fun() -> maps:get(reader, sys:get_state(A)) =:= none end),
        ok = lawspec_beam_endpoint:send(B, <<"next">>), ?assertEqual([<<"next">>], values(A, 1))
    end).

async_reads_are_correlated_and_expire_test() ->
    with_ends(#{}, #{}, fun(_, _, A, B, _) ->
        First = lawspec_beam_endpoint:receive_async(A, 1),
        receive {lawspec_channel, A, First, Result} -> ?assertEqual({error, receive_timeout}, Result)
        after 1000 -> error(no_timeout) end,
        Second = lawspec_beam_endpoint:receive_async(A, infinity),
        ok = lawspec_beam_endpoint:send(B, <<"received">>),
        receive {lawspec_channel, A, Second, Value} -> ?assertEqual({value, <<"received">>}, Value)
        after 1000 -> error(no_value) end
    end).

partition_reports_unreachable_and_healing_repairs_retries_test() ->
    with_ends(#{}, #{deadline => 150}, fun(Net, _, A, B, _) ->
        ok = lawspec_beam_memory_network:partition(Net, [[<<"a">>], [<<"b">>], [<<"c">>]]),
        ok = lawspec_beam_endpoint:send(B, <<"kept">>),
        ok = lawspec_beam_memory_network:heal(Net),
        ?assertEqual([<<"kept">>], values(A, 1)),
        ok = lawspec_beam_memory_network:partition(Net, [[<<"a">>], [<<"b">>], [<<"c">>]]),
        ok = lawspec_beam_endpoint:send(A, <<"lost">>),
        ?assertMatch({error, <<"the other end did not answer", _/binary>>}, lawspec_beam_endpoint:receive_body(A, 1000))
    end).

failed_take_keeps_service_responsive_test() ->
    with_ends(#{loss => 1}, #{deadline => 100}, fun(_, _, A, _, C) ->
        Address = lawspec_beam_endpoint:offer(A),
        ?assertException(error, {lawspec, {channel, _}}, lawspec_beam_endpoint:take(C, Address)),
        ?assertEqual(<<"mem://c/end">>, lawspec_beam_endpoint:address(C)),
        ?assertMatch({error, _}, lawspec_beam_endpoint:receive_body(C, 1000))
    end).

invalid_operations_do_not_destroy_the_endpoint_test() ->
    with_ends(#{}, #{}, fun(_, _, A, B, C) ->
        ?assertError({lawspec, {channel, invalid_payload}}, lawspec_beam_endpoint:send(A, 42)),
        ?assertError({lawspec, {channel, invalid_timeout}}, lawspec_beam_endpoint:receive_body(A, -1)),
        ?assertError({lawspec, {channel, invalid_operation}}, lawspec_beam_endpoint:take(C, <<"invalid">>)),
        ok = lawspec_beam_endpoint:send(A, <<"works">>), ?assertEqual([<<"works">>], values(B, 1)),
        ?assertError({lawspec, {channel, invalid_operation}}, lawspec_beam_endpoint:offer(A))
    end).

node_owns_endpoints_but_not_application_receivers_test() ->
    with_ends(#{}, #{}, fun(_, [Node | _], A, _, _) ->
        Owner = self(), Creator = spawn_monitor(fun() ->
            {ok, Extra} = lawspec_beam_endpoint:start(Node, <<"extra">>, #{}), Owner ! {extra, Extra}
        end),
        Extra = receive {extra, E} -> E end,
        {P, M} = Creator, receive {'DOWN', M, process, P, normal} -> ok end,
        ?assertEqual(<<"mem://a/extra">>, lawspec_beam_endpoint:address(Extra)),
        _ = lawspec_beam_node:register_receiver(Node, <<"application">>, self()),
        ok = lawspec_beam_node:stop(Node),
        ?assertNot(is_process_alive(A)), ?assertNot(is_process_alive(Extra))
    end).

node_kill_releases_all_owned_services_test() ->
    with_ends(#{}, #{}, fun(_, [Node | _], A, _, _) ->
        {ok, Extra} = lawspec_beam_endpoint:start(Node, <<"extra">>, #{}),
        Monitors = [{P, monitor(process, P)} || P <- [Node, A, Extra]],
        exit(Node, kill),
        lists:foreach(fun({P, M}) -> receive {'DOWN', M, process, P, _} -> ok
            after 1000 -> error(leaked_endpoint) end end, Monitors)
    end).

until(Body) -> until(Body, erlang:monotonic_time(millisecond) + 1000).
until(Body, Deadline) -> case Body() of
    true -> ok;
    false -> true = erlang:monotonic_time(millisecond) < Deadline, receive after 1 -> ok end, until(Body, Deadline)
end.
