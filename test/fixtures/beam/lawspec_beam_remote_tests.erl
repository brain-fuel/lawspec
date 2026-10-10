%% @doc Remote values are canonical, malformed calls have no side effects,
%% and retries invoke an actual actor or definition worker exactly once.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_remote_tests).
-include_lib("eunit/include/eunit.hrl").

integer() -> <<"(int Int64 _ _)">>.
entry(Body) -> #{arguments => [integer()], result => integer(), invoke => Body}.
with_nodes(Faults, Body) ->
    lawspec_beam_memory_network:with_network(Faults, fun(Net) ->
        {ok, A} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"a">>)),
        {ok, B} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"b">>)),
        try Body(Net, A, B) after lawspec_beam_node:stop(B), lawspec_beam_node:stop(A) end
    end).
proxy(Node, Address, Kind, Table) -> lawspec_beam_remote:connect(Node, Address, Kind, Table, 1000).

actual_actor_handles_each_faulty_call_once_test_() ->
    {timeout, 10, fun() -> with_nodes(#{seed => 734, loss => 0.2, duplicate => 0.4, delay => 0.002}, fun(_, A, B) ->
        Actor = lawspec_beam_actors:start(fun() -> 0 end),
        try
            Handler = entry(fun([N]) -> lawspec_beam_actors:call(Actor, fun(S) -> {N, S + N} end) end),
            Table = #{<<"add">> => Handler},
            Address = lawspec_beam_remote:serve(B, <<"counter">>, <<"call">>, Table),
            Remote = proxy(A, Address, <<"call">>, Table),
            Results = lawspec_beam_runtime:concurrently([fun() -> lawspec_beam_remote:call(Remote, <<"add">>, [N]) end
                || N <- lists:seq(1, 30)]),
            ?assertEqual(lists:seq(1, 30), Results),
            ?assertEqual(465, lawspec_beam_actors:state(Actor)),
            ok = lawspec_beam_node:stop(B),
            %% Serving does not take ownership of an application actor.
            ?assertEqual(465, lawspec_beam_actors:state(Actor))
        after lawspec_beam_actors:stop(Actor) end
    end) end}.

definition_content_hash_is_the_wire_selector_test() ->
    with_nodes(#{record => true, duplicate => 1}, fun(Net, A, B) ->
        Digest = <<"sha3-256:", (binary:copy(<<"a">>, 64))/binary>>,
        Count = atomics:new(1, []),
        Table = #{Digest => entry(fun([N]) -> atomics:add(Count, 1, 1), N + 1000 end)},
        Address = lawspec_beam_remote:serve(B, <<"definitions">>, <<"eval">>, Table),
        Remote = proxy(A, Address, <<"eval">>, Table),
        ?assertEqual(1007, lawspec_beam_remote:call(Remote, Digest, [7])),
        ?assertEqual(1, atomics:get(Count, 1)),
        Expected = <<73, Digest/binary, 14>>,
        ?assert(lists:any(fun(Bytes) -> case lawspec_beam_wire:read_frame(Bytes) of
            {ok, #{kind := <<"eval">>, payload := Expected}} -> true;
            _ -> false
        end end, lawspec_beam_memory_network:recorded(Net)))
    end).

bad_kind_unknown_hash_and_malformed_arguments_never_invoke_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Count = atomics:new(1, []),
        Table = #{<<"known">> => entry(fun([N]) -> atomics:add(Count, 1, 1), N end)},
        Address = lawspec_beam_remote:serve(B, <<"service">>, <<"eval">>, Table),
        Prefix = lawspec_beam_values:encode([<<"text">>], <<"known">>, #{}),
        Unknown = lawspec_beam_values:encode([<<"text">>], <<"other">>, #{}),
        lists:foreach(fun({Kind, Bytes}) ->
            ?assertMatch({3, _}, lawspec_beam_node:request(A, Address, Kind, Bytes, 1000))
        end, [{<<"call">>, <<Prefix/binary, 0>>}, {<<"eval">>, <<Unknown/binary, 0>>},
            {<<"eval">>, Prefix}, {<<"eval">>, <<Prefix/binary, 0, 0>>}, {<<"eval">>, <<255>>}]),
        ?assertEqual(0, atomics:get(Count, 1)),
        ?assertEqual(8, lawspec_beam_remote:call(proxy(A, Address, <<"eval">>, Table), <<"known">>, [8]))
    end).

client_rejects_wrong_arity_before_sending_test() ->
    with_nodes(#{record => true}, fun(Net, A, _) ->
        Remote = proxy(A, <<"mem://b/unused">>, <<"call">>, #{<<"add">> => entry(fun([N]) -> N end)}),
        ?assertError({lawspec, {remote, argument_count}}, lawspec_beam_remote:call(Remote, <<"add">>, [])),
        ?assertError({lawspec, {remote, argument_count}}, lawspec_beam_remote:call(Remote, <<"add">>, [1, 2])),
        ?assertError({lawspec, {remote, {unknown_selector, <<"missing">>}}}, lawspec_beam_remote:call(Remote, <<"missing">>, [])),
        ?assertEqual([], lawspec_beam_memory_network:recorded(Net))
    end).

application_failure_stopped_actor_and_rejection_remain_distinct_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Actor = lawspec_beam_actors:start(fun() -> 0 end), lawspec_beam_actors:stop(Actor),
        Table = #{<<"crash">> => entry(fun(_) -> error(application_failure) end),
            <<"stopped">> => entry(fun(_) -> lawspec_beam_actors:state(Actor) end)},
        Address = lawspec_beam_remote:serve(B, <<"failure">>, <<"call">>, Table),
        Remote = proxy(A, Address, <<"call">>, Table),
        ?assertException(error, {lawspec, {remote, {failed, _}}}, lawspec_beam_remote:call(Remote, <<"crash">>, [0])),
        ?assertException(error, {lawspec, {remote, {stopped, _}}}, lawspec_beam_remote:call(Remote, <<"stopped">>, [0])),
        Missing = proxy(A, Address, <<"call">>, #{<<"unknown">> => entry(fun([N]) -> N end)}),
        ?assertException(error, {lawspec, {remote, {rejected, _}}}, lawspec_beam_remote:call(Missing, <<"unknown">>, [0]))
    end).

native_data_and_unit_use_canonical_logical_values_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Text = <<"(data Parcel (ctor Parcel (int Int32 _ _) (maybe (text))))">>,
        Table = #{<<"read">> => #{arguments => [Text, <<"(unit)">>], result => Text,
            invoke => fun([P, ls_unit]) -> P end}},
        Address = lawspec_beam_remote:serve(B, <<"data">>, <<"eval">>, Table),
        Parcel = {ls_data, <<"Parcel">>, [42, {ls_data, <<"Maybe::Just">>, [<<"sent">>]}]},
        ?assertEqual(Parcel, lawspec_beam_remote:call(proxy(A, Address, <<"eval">>, Table), <<"read">>, [Parcel, ls_unit]))
    end).

node_closure_joins_nested_definition_workers_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        Parent = self(),
        Table = #{<<"wait">> => entry(fun(_) -> lawspec_beam_runtime:async_call(fun() ->
            Parent ! {waiting, self()}, receive finish -> 0 end
        end) end)},
        Address = lawspec_beam_remote:serve(B, <<"wait">>, <<"eval">>, Table),
        Remote = lawspec_beam_remote:connect(A, Address, <<"eval">>, Table, 200),
        {Caller, Monitor} = spawn_monitor(fun() ->
            ?assertException(error, {lawspec, {network, {unreachable, _}}}, lawspec_beam_remote:call(Remote, <<"wait">>, [0]))
        end),
        Worker = receive {waiting, P} -> P after 1000 -> error(no_worker) end,
        lawspec_beam_node:stop(B), ?assertNot(is_process_alive(Worker)),
        receive {'DOWN', Monitor, process, Caller, Reason} -> ?assertEqual(normal, Reason)
        after 1000 -> exit(Caller, kill), error(stuck_caller) end
    end).
