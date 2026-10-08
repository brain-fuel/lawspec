%% @doc Network scenarios retain ownership and causal metadata through real
%% loss, reordering, duplication, delivery receipts and ordered EOF.
%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(lawspec_beam_scenario_network_tests).
-include_lib("eunit/include/eunit.hrl").

int() -> [<<"int">>, <<"Int64">>, -16#8000000000000000, 16#7fffffffffffffff].
channel(Name, Types) -> [<<"channel">>, Name | [[<<"send">>, D] || D <- Types]].
box(Name, Type) -> [<<"mailbox">>, Name, Type].
with_io(Channels, Boxes, Forms, Body) ->
    lawspec_beam_scenario_io:with_io(Channels, Boxes,
        #{network => true, wire => [<<"wire">> | Forms], shake => 931,
            faults => #{loss => 0.2, duplicate => 0.5, delay => 0.005}}, Body).
child(Id, Ends, Sends, Receives) -> #{id => Id, ends => Ends, sends => Sends, receives => Receives}.
run(Hub, Id, Body) -> spawn_monitor(fun() ->
    ok = lawspec_beam_scenario_io:enter(Hub, Id), try Body() after lawspec_beam_scenario_io:leave(Hub, Id) end
end).
join({Pid, M}) -> receive {'DOWN', M, process, Pid, normal} -> ok;
    {'DOWN', M, process, Pid, Reason} -> error({worker_failed, Reason})
    after 3000 -> error(worker_stuck) end.
kill({Pid, M}) -> exit(Pid, kill), receive {'DOWN', M, process, Pid, killed} -> ok after 1000 -> error(worker_stuck) end.
c(Side) -> {'end', <<"c">>, Side}.
r(Side) -> {'end', <<"r">>, Side}.

sender_exit_does_not_overtake_inflight_values_test_() ->
    {timeout, 10, fun() -> with_io([<<"c">>], #{}, [channel(<<"c">>, lists:duplicate(50, int()))], fun(H) ->
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [c(0)], #{}, [])]),
        join(run(H, 1, fun() -> lists:foreach(fun(N) ->
            ok = lawspec_beam_scenario_io:send(H, 1, c(0), N, #{1 => N})
        end, lists:seq(1, 50)) end)),
        ?assertEqual([{value, N, #{1 => N}} || N <- lists:seq(1, 50)],
            [lawspec_beam_scenario_io:receive_value(H, root, c(1)) || _ <- lists:seq(1, 50)]),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, c(1))),
        #{frames := Frames, lost := Lost, duplicated := Duplicated} = lawspec_beam_scenario_io:network_stats(H),
        ?assert(Frames > 100), ?assert(Lost > 0), ?assert(Duplicated > 0)
    end) end}.

parallel_mailbox_values_keep_their_exact_sender_clock_test_() ->
    {timeout, 10, fun() -> with_io([], #{<<"m">> => 100}, [box(<<"m">>, int())], fun(H) ->
        ok = lawspec_beam_scenario_io:fork(H, root, [child(I, [], #{<<"m">> => 5}, []) || I <- lists:seq(1, 20)]),
        Workers = [run(H, I, fun() -> lists:foreach(fun(N) ->
            ok = lawspec_beam_scenario_io:send(H, I, {mailbox, <<"m">>}, I * 100 + N, #{I => N})
        end, lists:seq(1, 5)) end) || I <- lists:seq(1, 20)],
        Got = [lawspec_beam_scenario_io:receive_value(H, root, {mailbox, <<"m">>}) || _ <- lists:seq(1, 100)],
        ?assertEqual(lists:sort([{value, I * 100 + N, #{I => N}} || I <- lists:seq(1, 20), N <- lists:seq(1, 5)]), lists:sort(Got)),
        lists:foreach(fun join/1, Workers),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, <<"m">>})),
        ?assertEqual(0, maps:get(pending_requests, lawspec_beam_scenario_io:network_stats(H)))
    end) end}.

dead_producer_does_not_abandon_an_accepted_mailbox_send_test() ->
    with_io([], #{<<"m">> => 2}, [box(<<"m">>, int())], fun(H) ->
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [], #{<<"m">> => 2}, [])]),
        %% Hold the receiving node so the first request is certainly in
        %% flight when its original sending process dies.
        Network = maps:get(network, sys:get_state(H)),
        [Receiver] = maps:keys(maps:get(inboxes, Network)),
        ok = sys:suspend(Receiver),
        W = run(H, 1, fun() -> lawspec_beam_scenario_io:send(H, 1, {mailbox, <<"m">>}, 17, #{1 => 4}) end),
        try
            until(fun() -> map_size(maps:get(flights, maps:get(network, sys:get_state(H)))) =:= 1 end), kill(W)
        after sys:resume(Receiver) end,
        ?assertEqual({value, 17, #{1 => 4}}, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, <<"m">>})),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, {mailbox, <<"m">>}))
    end).

delegated_end_survives_its_sending_process_test() ->
    with_io([<<"c">>, <<"r">>], #{}, [channel(<<"c">>, [[<<"end">>]]), channel(<<"r">>, [int()])], fun(H) ->
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [c(0), r(0)], #{}, [])]),
        join(run(H, 1, fun() -> lawspec_beam_scenario_io:send(H, 1, c(0), {lawspec_scenario_end, <<"r">>, 0}, #{1 => 1}) end)),
        ?assertEqual({value, {lawspec_scenario_end, <<"r">>, 0}, #{1 => 1}}, lawspec_beam_scenario_io:receive_value(H, root, c(1))),
        ok = lawspec_beam_scenario_io:send(H, root, r(0), 42, #{root => 1}),
        ?assertEqual({value, 42, #{root => 1}}, lawspec_beam_scenario_io:receive_value(H, root, r(1)))
    end).

dead_receiver_releases_delegations_arriving_later_test() ->
    lists:foreach(fun(IsMailbox) ->
        {Channels, Boxes, Forms, Destination, ChildEnds, ChildBoxes} = case IsMailbox of
            false -> {[<<"c">>, <<"r">>], #{}, [channel(<<"c">>, [[<<"end">>]]), channel(<<"r">>, [int()])], c(0), [c(1)], []};
            true -> {[<<"r">>], #{<<"m">> => 1}, [channel(<<"r">>, [int()]), box(<<"m">>, [<<"end">>])], {mailbox, <<"m">>}, [], [<<"m">>]}
        end,
        with_io(Channels, Boxes, Forms, fun(H) ->
            ok = lawspec_beam_scenario_io:fork(H, root, [child(1, ChildEnds, #{}, ChildBoxes)]),
            join(run(H, 1, fun() -> ok end)),
            ok = lawspec_beam_scenario_io:send(H, root, Destination, {lawspec_scenario_end, <<"r">>, 0}, #{}),
            ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, r(1)))
        end)
    end, [false, true]).

receiver_death_releases_an_end_already_in_flight_test() ->
    with_io([<<"c">>, <<"r">>], #{}, [channel(<<"c">>, [[<<"end">>]]), channel(<<"r">>, [int()])], fun(H) ->
        Owner = self(),
        ok = lawspec_beam_scenario_io:fork(H, root, [child(1, [c(1)], #{}, [])]),
        W = run(H, 1, fun() -> Owner ! ready, receive finish -> ok end end),
        receive ready -> ok end,
        Network = maps:get(network, sys:get_state(H)), Net = maps:get(network, Network),
        Groups = [[lawspec_beam_node:address(Node)] || Node <- maps:get(nodes, Network)],
        ok = lawspec_beam_memory_network:partition(Net, Groups),
        ok = lawspec_beam_scenario_io:send(H, root, c(0), {lawspec_scenario_end, <<"r">>, 0}, #{}),
        kill(W),
        until(fun() -> maps:get(closed, maps:get(c(1), maps:get(queues, sys:get_state(H)))) end),
        ok = lawspec_beam_memory_network:heal(Net),
        ?assertEqual(gone, lawspec_beam_scenario_io:receive_value(H, root, r(1)))
    end).

network_runs_require_wire_types_for_every_destination_test() ->
    ?assertEqual({error, {lawspec, scenario_wire_required}},
        lawspec_beam_scenario_io:start([<<"c">>], #{}, #{network => true})),
    ?assertEqual({error, {lawspec, {scenario_network, mailbox_wire_required}}},
        lawspec_beam_scenario_io:start([], #{<<"m">> => 1}, #{network => true, wire => [<<"wire">>]})).

text_resembling_an_endpoint_remains_text_test() ->
    with_io([<<"c">>, <<"r">>], #{}, [channel(<<"c">>, [[<<"text">>]]), channel(<<"r">>, [])], fun(H) ->
        ok = lawspec_beam_scenario_io:send(H, root, c(0), <<"r#0">>, #{}),
        ?assertEqual({value, <<"r#0">>, #{}}, lawspec_beam_scenario_io:receive_value(H, root, c(1)))
    end).

data_descriptors_use_canonical_wire_values_test() ->
    Data = [<<"data">>, {quoted, <<"Packet">>}, [<<"ctor">>, {quoted, <<"Packet::Data">>}, int(), [<<"text">>]]],
    Type = [<<"ref">>, {quoted, <<"Packet">>}], Value = {ls_data, <<"Packet::Data">>, [-7, <<"hello">>]},
    with_io([<<"c">>], #{}, [Data, channel(<<"c">>, [Type])], fun(H) ->
        ok = lawspec_beam_scenario_io:send(H, root, c(0), Value, #{}),
        ?assertEqual({value, Value, #{}}, lawspec_beam_scenario_io:receive_value(H, root, c(1))),
        Net = maps:get(network, maps:get(network, sys:get_state(H))),
        Bodies = [Body || Bytes <- lawspec_beam_memory_network:recorded(Net),
            {ok, #{kind := <<"chan">>, payload := Payload}} <- [lawspec_beam_wire:read_frame(Bytes)],
            {N, _, Body} <- [lawspec_beam_wire:read_channel(Payload)], N >= 0],
        Canonical = lawspec_beam_values:encode(Type, Value, #{<<"Packet">> => Data}),
        ?assert(lists:member(<<0, Canonical/binary>>, Bodies))
    end).

closing_hub_joins_nodes_endpoints_and_timers_test() ->
    with_io([<<"c">>], #{<<"m">> => 1}, [channel(<<"c">>, [int()]), box(<<"m">>, int())], fun(H) ->
        State = maps:get(network, sys:get_state(H)),
        Services = [maps:get(network, State)] ++ maps:get(nodes, State) ++ maps:keys(maps:get(endpoints, State)),
        ok = lawspec_beam_scenario_io:stop(H),
        ?assert(lists:all(fun(P) -> not is_process_alive(P) end, Services))
    end).

killing_hub_releases_every_owned_network_service_test() ->
    with_io([<<"c">>], #{<<"m">> => 1}, [channel(<<"c">>, [int()]), box(<<"m">>, int())], fun(H) ->
        State = maps:get(network, sys:get_state(H)),
        Services = [H, maps:get(network, State)] ++ maps:get(nodes, State) ++ maps:keys(maps:get(endpoints, State)),
        Monitors = [{P, monitor(process, P)} || P <- Services], exit(H, kill),
        lists:foreach(fun({P, M}) -> receive {'DOWN', M, process, P, _} -> ok after 1000 -> error(leaked_service) end end, Monitors)
    end).

network_schedules_and_all_crash_boundaries_test_() ->
    {timeout, 60, fun() ->
        lists:foreach(fun({Channels, Boxes, Body, Wire}) ->
            Spec = iolist_to_binary(["(scenario \"network\" counter) (channels ", Channels,
                ") (mailboxes ", Boxes, ") (process ", Body, ") (wire ", Wire, ")"]),
            Program = lawspec_beam_scenario:new(Spec), Model = lawspec_beam_model_tests:counter(true),
            lists:foreach(fun(Seed) -> ?assertEqual(ok, lawspec_beam_scenario:execute(Model, Program, Seed, #{network => true})) end, lists:seq(1, 5)),
            lists:foreach(fun({Id, N}) -> lists:foreach(fun(At) ->
                ?assertEqual(ok, lawspec_beam_scenario:execute(Model, Program, At, #{network => true, victim => {Id, At}}))
            end, lists:seq(0, N)) end, maps:get(branches, Program))
        end, [
            {"c", "", "(par (process (call add x (int 5)) (send c (var x))) (process (receiveor c y (process (call read _))) (expect y (int 5))))",
                "(channel c (send (int Int64 -9223372036854775808 9223372036854775807)))"},
            {"ask reply", "", "(par (process (send ask (var reply))) (process (receive ask r) (call add x (int 5)) (send r (var x))) (process (receive reply n) (expect n (int 5))))",
                "(channel ask (send (end))) (channel reply (send (int Int64 -9223372036854775808 9223372036854775807)))"},
            {"", "m", "(par (process (call add a (int 3)) (send m (var a))) (process (call add b (int 4)) (send m (var b))) (process (receive m x) (receive m y) (call read z) (expect z (int 7))))",
                "(mailbox m (int Int64 -9223372036854775808 9223372036854775807))"}
        ])
    end}.

until(Body) -> until(Body, erlang:monotonic_time(millisecond) + 1000).
until(Body, Deadline) -> case Body() of
    true -> ok;
    false -> true = erlang:monotonic_time(millisecond) < Deadline, receive after 1 -> ok end, until(Body, Deadline)
end.
