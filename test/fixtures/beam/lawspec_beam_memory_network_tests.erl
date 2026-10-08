%% @doc Seeded packet faults, node ownership and delayed-delivery lifetimes.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_memory_network_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

with_net(Options, Body) -> lawspec_beam_memory_network:with_network(Options, Body).
register_pair(N) ->
    ok = lawspec_beam_memory_network:register(N, <<"a">>, self()),
    ok = lawspec_beam_memory_network:register(N, <<"b">>, self()).
messages(N, Count) -> [receive {lawspec_network, N, From, Data} -> {From, Data}
    after 1000 -> error(packet_not_delivered) end || _ <- lists:seq(1, Count)].
drain(N) -> receive {lawspec_network, N, _, _} -> drain(N) after 0 -> ok end.

ordinary_and_explicit_test_transports_test() ->
    with_net(#{}, fun(N) ->
        ?assertMatch(#{address := <<"mem://a">>, insecure_for_tests := false}, lawspec_beam_memory_network:transport(N, <<"a">>)),
        ?assertMatch(#{insecure_for_tests := true}, lawspec_beam_memory_network:insecure_transport_for_tests(N, <<"a">>)),
        register_pair(N),
        ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<"hello">>),
        ?assertEqual([{<<"mem://a">>, <<"hello">>}], messages(N, 1)),
        ?assertEqual([], lawspec_beam_memory_network:recorded(N))
    end).

loss_and_duplication_are_real_deliveries_test() ->
    with_net(#{loss => 1, record => true}, fun(N) ->
        register_pair(N),
        ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<"lost">>),
        ?assertMatch([#{outcome := lost}], lawspec_beam_memory_network:trace(N)),
        ?assertEqual(#{}, maps:get(pending, sys:get_state(N))),
        ?assertEqual([<<"lost">>], lawspec_beam_memory_network:recorded(N))
    end),
    with_net(#{duplicate => 1, delay => 0.002}, fun(N) ->
        register_pair(N),
        lists:foreach(fun(I) -> ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<I>>) end, lists:seq(1, 30)),
        Values = messages(N, 60),
        ?assertEqual(lists:sort(lists:append([[{<<"mem://a">>, <<I>>}, {<<"mem://a">>, <<I>>}] || I <- lists:seq(1, 30)])),
            lists:sort(Values))
    end).

delay_can_reorder_packets_test() ->
    with_net(#{seed => 94, delay => 0.05, record => true}, fun(N) ->
        register_pair(N),
        lists:foreach(fun(I) -> ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<I>>) end, lists:seq(1, 30)),
        Got = messages(N, 30), Ordered = [{<<"mem://a">>, <<I>>} || I <- lists:seq(1, 30)],
        ?assertEqual(Ordered, lists:sort(Got)), ?assertNotEqual(Ordered, Got)
    end).

partition_then_heal_does_not_replay_dropped_packets_test() ->
    with_net(#{record => true}, fun(N) ->
        register_pair(N),
        ok = lawspec_beam_memory_network:partition(N, [[<<"a">>], [<<"b">>]]),
        ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<"old">>),
        ok = lawspec_beam_memory_network:heal(N),
        ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<"new">>),
        ?assertEqual([{<<"mem://a">>, <<"new">>}], messages(N, 1)),
        ?assertMatch([#{outcome := partitioned}, #{outcome := sent}], lawspec_beam_memory_network:trace(N))
    end).

node_death_discards_pending_packets_before_address_reuse_test() ->
    with_net(#{seed => 1, delay => 10, record => true}, fun(N) ->
        ok = lawspec_beam_memory_network:register(N, <<"a">>, self()),
        {Old, Monitor} = spawn_monitor(fun() -> receive finish -> ok end end),
        ok = lawspec_beam_memory_network:register(N, <<"b">>, Old),
        ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<"old">>),
        ?assertEqual(1, map_size(maps:get(pending, sys:get_state(N)))),
        exit(Old, kill), receive {'DOWN', Monitor, process, Old, killed} -> ok end,
        ok = lawspec_beam_memory_network:register(N, <<"b">>, self()),
        ?assertEqual(#{}, maps:get(pending, sys:get_state(N))),
        ok = lawspec_beam_memory_network:unregister(N, <<"b">>),
        ?assertEqual({error, {unreachable, <<"mem://b">>}}, lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<>>))
    end).

node_registration_and_source_ownership_test() ->
    with_net(#{}, fun(N) ->
        register_pair(N),
        ?assertEqual({error, already_registered}, lawspec_beam_memory_network:register(N, <<"a">>, self())),
        ?assertEqual({error, not_node_owner}, lawspec_beam_memory_network:send(N, <<"c">>, <<"b">>, <<>>)),
        {P, Ref} = spawn_monitor(fun() ->
            ?assertEqual({error, not_node_owner}, lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<>>)),
            ?assertEqual({error, not_node_owner}, lawspec_beam_memory_network:unregister(N, <<"a">>))
        end),
        receive {'DOWN', Ref, process, P, Reason} -> ?assertEqual(normal, Reason) end
    end).

network_scope_closes_on_owner_death_test() ->
    Owner = self(),
    {P, Ref} = spawn_monitor(fun() ->
        {ok, N} = lawspec_beam_memory_network:start(#{delay => 10}),
        register_pair(N), ok = lawspec_beam_memory_network:send(N, <<"a">>, <<"b">>, <<"pending">>),
        Owner ! {network, N}, receive finish -> ok end
    end),
    N = receive {network, Network} -> Network end, NM = monitor(process, N),
    exit(P, kill), receive {'DOWN', Ref, process, P, killed} -> ok end,
    receive {'DOWN', NM, process, N, normal} -> ok after 1000 -> error(network_leaked) end.

invalid_options_fail_before_starting_test() ->
    ?assertError({lawspec, {memory_network, {invalid_probability, loss}}}, lawspec_beam_memory_network:start(#{loss => 2})),
    ?assertError({lawspec, {memory_network, invalid_delay}}, lawspec_beam_memory_network:start(#{delay => -1})).

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path), Cases = json:decode(Bytes),
    lists:foreach(fun(#{<<"seed">> := Seed, <<"loss">> := Loss, <<"duplicate">> := Duplicate,
            <<"trace">> := Expected}) ->
        {ok, N} = lawspec_beam_memory_network:start(#{seed => Seed, loss => Loss, duplicate => Duplicate, record => true}),
        try
            register_pair(N),
            lists:foreach(fun(I) ->
                case I rem 7 of
                    0 -> lawspec_beam_memory_network:partition(N, [[<<"a">>], [<<"b">>]]);
                    1 -> lawspec_beam_memory_network:heal(N);
                    _ -> ok
                end,
                To = case I rem 11 of 0 -> <<"missing">>; _ -> <<"b">> end,
                lawspec_beam_memory_network:send(N, <<"a">>, To, integer_to_binary(I))
            end, lists:seq(0, 29)),
            Actual = [#{<<"outcome">> => atom_to_binary(maps:get(outcome, E)),
                <<"slots">> => maps:get(delay_slots, E, [])} || E <- lawspec_beam_memory_network:trace(N)],
            ?assertEqual(Expected, Actual)
        after lawspec_beam_memory_network:stop(N), drain(N) end
    end, Cases),
    io:format("~B seeded network fault traces match the portable transport~n", [length(Cases)]).
