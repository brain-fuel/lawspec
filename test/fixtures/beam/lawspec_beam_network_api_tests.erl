%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
-module(lawspec_beam_network_api_tests).
-include_lib("eunit/include/eunit.hrl").

native_identity_options_secure_nodes_and_scopes_test() ->
    N = lawspec_network, Identity = N:identity_from_seed(<<0:256>>), Other = N:new_identity(),
    ?assertEqual(1952, byte_size(N:public_key(Identity))),
    Fingerprint = N:fingerprint(Identity), ?assertEqual(64, byte_size(Fingerprint)),
    Options = N:with_trusted(N:with_identity(N:options(), Identity), [N:fingerprint(Other)]),
    OtherOptions = N:with_trusted(N:with_identity(N:options(), Other), [Fingerprint]),
    {Net, A, B} = N:with_memory({memory_options, 55, 0.1, 0.2, 0.001, true}, fun(Net) ->
        N:with_node(N:memory_transport(Net, <<"a">>), Options, fun(A) ->
            N:with_node(N:memory_transport(Net, <<"b">>), OtherOptions, fun(B) ->
                ?assertEqual(Fingerprint, N:node_fingerprint(A)),
                Address = lawspec_beam_node:register_handler(B, <<"echo">>, fun(#{payload := Bytes}) -> {0, Bytes} end),
                ?assertEqual({0, <<"native">>}, lawspec_beam_node:request(A, Address, <<"call">>, <<"native">>, 2000)),
                ?assert(lists:all(fun(<<"LS", 1, _, _/binary>>) -> true; (_) -> false end, N:recorded(Net))),
                {Net, A, B}
            end)
        end)
    end),
    lists:foreach(fun(Pid) -> ?assertNot(is_process_alive(Pid)) end, [Net, A, B]).

scopes_join_on_exception_and_release_the_name_test() ->
    lawspec_network:with_memory(#{}, fun(Net) ->
        T = lawspec_network:insecure_memory_transport_for_tests(Net, <<"exception">>),
        ?assertError(raised_in_body, lawspec_network:with_node(T, fun(Node) ->
            put(node_in_body, Node), error(raised_in_body)
        end)),
        ?assertNot(is_process_alive(erase(node_in_body))),
        Node = lawspec_network:open(T),
        ?assertEqual(<<"mem://exception">>, lawspec_network:address(Node)),
        ?assertError({lawspec, {network, insecure_node}}, lawspec_network:node_fingerprint(Node)),
        ?assertEqual(ok, lawspec_network:close(Node)), ?assertEqual(ok, lawspec_network:close(Node))
    end).

creator_death_closes_native_nodes_test() ->
    lawspec_network:with_memory(#{}, fun(Net) ->
        Parent = self(), {Owner, Monitor} = spawn_monitor(fun() ->
            Node = lawspec_network:open(lawspec_network:memory_transport(Net, <<"owned">>)),
            Parent ! {node, Node}, receive finish -> ok end
        end),
        Node = receive {node, Pid} -> Pid after 1000 -> error(node_not_created) end,
        #{connection := #{pid := Layer}} = sys:get_state(Node),
        NodeMonitor = monitor(process, Node), LayerMonitor = monitor(process, Layer), exit(Owner, kill),
        receive {'DOWN', Monitor, process, Owner, killed} -> ok after 1000 -> error(owner_alive) end,
        receive {'DOWN', NodeMonitor, process, Node, _} -> ok after 1000 -> error(node_leaked) end,
        receive {'DOWN', LayerMonitor, process, Layer, _} -> ok after 1000 -> error(layer_leaked) end
    end).

fault_controls_and_default_scope_api_test() ->
    N = lawspec_network,
    N:with_memory(#{record => true}, fun(Net) ->
        N:with_node(N:insecure_memory_transport_for_tests(Net, <<"a">>), fun(A) ->
            N:with_node(N:insecure_memory_transport_for_tests(Net, <<"b">>), fun(B) ->
                Address = lawspec_beam_node:register_handler(B, <<"echo">>, fun(#{payload := Bytes}) -> {0, Bytes} end),
                ok = N:partition(Net, [[<<"a">>], [<<"b">>]]),
                ?assertError({lawspec, {network, {unreachable, Address}}}, lawspec_beam_node:request(A, Address, <<"call">>, <<>>, 10)),
                ok = N:heal(Net),
                ?assertEqual({0, <<>>}, lawspec_beam_node:request(A, Address, <<"call">>, <<>>, 1000)),
                ?assertNotEqual([], N:recorded(Net))
            end)
        end)
    end).

invalid_options_fail_before_allocating_a_listener_test() ->
    N = lawspec_network,
    lists:foreach(fun(Transport) ->
        ?assertEqual({error, invalid_transport_options}, lawspec_beam_socket_transport:start(Transport, self()))
    end, [N:tcp(<<"localhost">>, -1), N:http(<<"localhost">>, 65536),
        N:tcp(<<"bad\r\nhost">>, 80), N:advertise(N:http(<<"localhost">>, 0), <<"/path">>)]),
    ?assertEqual(#{trusted => none}, N:trust_on_first_use(N:with_trusted(N:options(), []))),
    ?assertError({lawspec, invalid_node_identity}, N:identity_from_seed(<<1>>)).
