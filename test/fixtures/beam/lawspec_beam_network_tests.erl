%% @doc Secure records match all targets; handshake faults, identities and
%% process lifetimes are exercised through real nodes and packet delivery.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_network_tests).
-include_lib("eunit/include/eunit.hrl").

node_at(Net, Name, Seed, Trusted) ->
    {ok, N} = lawspec_beam_node:start(lawspec_beam_memory_network:transport(Net, Name), #{identity => Seed, trusted => Trusted}), N.
seed(N) -> binary:copy(<<N>>, 32).
layer(Node) -> maps:get(pid, maps:get(connection, sys:get_state(Node))).
with_nodes(Faults, Body) ->
    lawspec_beam_memory_network:with_network(Faults, fun(Net) ->
        A = node_at(Net, <<"a">>, seed(1), none), B = node_at(Net, <<"b">>, seed(2), none),
        try Body(Net, A, B) after lawspec_beam_node:stop(B), lawspec_beam_node:stop(A) end
    end).
echo(Node) -> lawspec_beam_node:register_handler(Node, <<"echo">>, fun(#{payload := Bytes}) -> {0, Bytes} end).
ask(Node, Address, Bytes) -> lawspec_beam_node:request(Node, Address, <<"call">>, Bytes, 2000).
until(Fun) -> until(Fun, erlang:monotonic_time(millisecond) + 1000).
until(Fun, Deadline) -> case Fun() of true -> ok; false ->
    true = erlang:monotonic_time(millisecond) < Deadline, receive after 1 -> ok end, until(Fun, Deadline) end.

shared_handshake_vector_test() ->
    {ok, Spec} = file:read_file("examples/specs/distribution.lawspec"),
    {match, [Vector]} = re:run(Spec, <<"handshakeAgrees \"([^\"]+)\"">>, [{capture, [1], binary}]),
    [I, R, K, S, A, B, C, N, F, H, W, ExpectedKey, ExpectedRecord] = binary:split(Vector, <<" ">>, [global]),
    X = fun binary:decode_hex/1,
    First = lawspec_beam_network_crypto:identity(X(I)), Second = lawspec_beam_network_crypto:identity(X(R)),
    {Kem, _} = lawspec_beam_crypto:mlkem_keypair(X(K)),
    Hello = lawspec_beam_network_crypto:hello(X(S), A, lawspec_beam_network_crypto:public(First), Kem),
    Welcome = lawspec_beam_network_crypto:welcome(X(S), B, lawspec_beam_network_crypto:public(Second), X(C), Hello),
    Key = lawspec_beam_network_crypto:key(lawspec_beam_crypto:mlkem_decapsulate(X(K), X(C)), Hello, Welcome),
    ?assertEqual(X(H), lawspec_beam_crypto:sha3_256(Hello)),
    ?assertEqual(X(W), lawspec_beam_crypto:sha3_256(Welcome)), ?assertEqual(X(ExpectedKey), Key),
    Record = lawspec_beam_network_crypto:seal(Key, X(S), 0, X(F), X(N)),
    ?assertEqual(X(ExpectedRecord), Record),
    {3, Session, 0, Sealed} = lawspec_beam_network_crypto:read(Record),
    ?assertEqual({ok, X(F)}, lawspec_beam_network_crypto:open(Key, Session, 0, Sealed)),
    ?assertEqual(error, lawspec_beam_network_crypto:open(Key, Session, 1, Sealed)).

secure_calls_execute_once_under_loss_and_duplicates_test_() ->
    {timeout, 10, fun() -> with_nodes(#{seed => 9235, loss => 0.2, duplicate => 0.6, delay => 0.002, record => true}, fun(Net, A, B) ->
        Counter = atomics:new(1, []),
        Address = lawspec_beam_node:register_handler(B, <<"echo">>, fun(#{payload := Bytes}) -> atomics:add(Counter, 1, 1), {0, Bytes} end),
        Results = lawspec_beam_runtime:concurrently([fun() -> ask(A, Address, <<I>>) end || I <- lists:seq(1, 25)]),
        ?assertEqual([{0, <<I>>} || I <- lists:seq(1, 25)], Results), ?assertEqual(25, atomics:get(Counter, 1)),
        Records = lawspec_beam_memory_network:recorded(Net),
        ?assert(lists:all(fun(<<"LS", 1, _, _/binary>>) -> true; (_) -> false end, Records)),
        ?assert(lists:any(fun(<<"LS", 1, 3, _/binary>>) -> true; (_) -> false end, Records)),
        ?assertEqual(0, map_size(maps:get(pending, sys:get_state(layer(A))))),
        ?assertEqual(1, map_size(maps:get(known, sys:get_state(layer(B)))))
    end) end}.

simultaneous_handshakes_and_bidirectional_calls_test() ->
    with_nodes(#{duplicate => 0.5, delay => 0.002}, fun(_, A, B) ->
        AA = echo(A), BB = echo(B),
        ?assertEqual([{0, <<"left">>}, {0, <<"right">>}], lawspec_beam_runtime:concurrently([
            fun() -> ask(A, BB, <<"left">>) end, fun() -> ask(B, AA, <<"right">>) end]))
    end).

explicit_trust_accepts_both_peers_and_empty_trust_refuses_test() ->
    lawspec_beam_memory_network:with_network(#{}, fun(Net) ->
        FA = lawspec_beam_network_crypto:fingerprint(lawspec_beam_network_crypto:identity(seed(1))),
        FB = lawspec_beam_network_crypto:fingerprint(lawspec_beam_network_crypto:identity(seed(2))),
        A = node_at(Net, <<"a">>, seed(1), [string:uppercase(FB)]), B = node_at(Net, <<"b">>, seed(2), [FA]),
        C = node_at(Net, <<"c">>, seed(3), []),
        try
            Address = echo(B), ?assertEqual({0, <<"trusted">>}, ask(A, Address, <<"trusted">>)),
            ?assertException(error, {lawspec, {network, {unreachable, _}}}, lawspec_beam_node:request(C, Address, <<"call">>, <<>>, 80)),
            ?assertEqual(0, map_size(maps:get(known, sys:get_state(layer(C)))))
        after lists:foreach(fun lawspec_beam_node:stop/1, [A, B, C]) end
    end).

tampered_records_wrong_direction_and_changed_hello_are_ignored_test() ->
    with_nodes(#{record => true}, fun(Net, A, B) ->
        Address = echo(B), ?assertEqual({0, <<"secret">>}, ask(A, Address, <<"secret">>)),
        Layers = [layer(A), layer(B)],
        Records = lawspec_beam_memory_network:recorded(Net),
        Snapshot = [maps:get(sessions, sys:get_state(L)) || L <- Layers],
        Bad = lists:append([[<<>>, <<"plain">>, <<Record/binary, 0>>, flip(Record)] || Record <- Records]),
        lists:foreach(fun(L) -> lists:foreach(fun(R) -> L ! {lawspec_network, Net, <<"mem://forged">>, R} end, Bad) end, Layers),
        [sys:get_state(L) || L <- Layers],
        ?assertEqual(Snapshot, [maps:get(sessions, sys:get_state(L)) || L <- Layers]),
        ?assertEqual({0, <<"still alive">>}, ask(A, Address, <<"still alive">>))
    end).
flip(Bytes) -> Size = byte_size(Bytes) - 1, <<Prefix:Size/binary, Last>> = Bytes, <<Prefix/binary, (Last bxor 1)>>.

first_identity_at_address_stays_pinned_test() ->
    with_nodes(#{}, fun(Net, A, B) ->
        ?assertEqual({0, <<>>}, ask(A, echo(B), <<>>)),
        Layer = layer(A), Before = sys:get_state(Layer),
        Other = lawspec_beam_network_crypto:identity(seed(5)), Session = crypto:strong_rand_bytes(16),
        {Kem, _} = lawspec_beam_crypto:mlkem_keypair(crypto:strong_rand_bytes(64)),
        Body = lawspec_beam_network_crypto:hello(Session, <<"mem://b">>, lawspec_beam_network_crypto:public(Other), Kem),
        Signature = lawspec_beam_network_crypto:sign(Other, <<"lawspec-handshake-v1-hello", Body/binary>>),
        Layer ! {lawspec_network, Net, <<"mem://b">>, lawspec_beam_network_crypto:record(1, Body, Signature)},
        After = sys:get_state(Layer),
        ?assertEqual(maps:get(known, Before), maps:get(known, After)),
        ?assertEqual(maps:get(sessions, Before), maps:get(sessions, After))
    end).

node_shutdown_joins_layer_and_kill_releases_address_test() ->
    with_nodes(#{loss => 1}, fun(Net, A, B) ->
        Layer = layer(A), ?assertException(error, {lawspec, {network, {unreachable, _}}},
            lawspec_beam_node:request(A, echo(B), <<"call">>, <<>>, 20)),
        lawspec_beam_node:stop(A), ?assertNot(is_process_alive(Layer)),
        OtherLayer = layer(B), exit(B, kill),
        until(fun() -> not is_process_alive(OtherLayer) end),
        Replacement = node_at(Net, <<"b">>, seed(2), none), lawspec_beam_node:stop(Replacement)
    end).

status_hides_identity_and_session_keys_test() ->
    with_nodes(#{}, fun(_, A, B) ->
        ?assertEqual({0, <<>>}, ask(A, echo(B), <<>>)),
        Status = term_to_binary(sys:get_status(layer(A))),
        ?assertEqual(nomatch, binary:match(Status, seed(1))),
        #{sessions := Sessions} = sys:get_state(layer(A)),
        lists:foreach(fun(#{key := Key}) -> ?assertEqual(nomatch, binary:match(Status, Key)) end, maps:values(Sessions))
    end).

reflected_valid_record_cannot_invoke_the_sender_test() ->
    with_nodes(#{}, fun(Net, A, B) ->
        ?assertEqual({0, <<>>}, ask(A, echo(B), <<>>)),
        Count = atomics:new(1, []),
        lawspec_beam_node:register_handler(A, <<"reflected">>, fun(_) -> atomics:add(Count, 1, 1), {0, <<>>} end),
        Layer = layer(A), [{Session, #{key := Key, direction := Direction}}] = maps:to_list(maps:get(sessions, sys:get_state(Layer))),
        Frame = lawspec_beam_wire:frame(<<"call">>, <<"reflected">>, <<"mem://b">>, 9988, <<>>),
        Layer ! {lawspec_network, Net, <<"mem://b">>, lawspec_beam_network_crypto:seal(Key, Session, Direction, Frame)},
        _ = sys:get_state(Layer), _ = lawspec_beam_node:address(A),
        ?assertEqual(0, atomics:get(Count, 1))
    end).

handshake_deadline_releases_queued_plaintext_test_() ->
    {timeout, 8, fun() -> with_nodes(#{loss => 1}, fun(_, A, B) ->
        ?assertException(error, {lawspec, {network, {unreachable, _}}}, lawspec_beam_node:request(A, echo(B), <<"call">>, <<"queued">>, 20)),
        Layer = layer(A), ?assertEqual(1, map_size(maps:get(pending, sys:get_state(Layer)))),
        until(fun() -> map_size(maps:get(pending, sys:get_state(Layer))) =:= 0 end,
            erlang:monotonic_time(millisecond) + 6000)
    end) end}.

configuration_resolves_relative_paths_and_validates_keys_test() ->
    Directory = filename:join(".artifacts/0.22.0", "network-config-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Directory, "unused")),
    Path = filename:absname(filename:join(Directory, "lawspec-network.conf")),
    Fingerprint = lawspec_beam_network_crypto:fingerprint(lawspec_beam_network_crypto:identity(seed(2))),
    ok = file:write_file(filename:join(Directory, "my seed"), binary:encode_hex(seed(1))),
    ok = file:write_file(filename:join(Directory, "peers"), <<Fingerprint/binary, "\n">>),
    ok = file:write_file(Path, <<"# keys\nidentity my seed\ntrusted peers\n">>),
    Previous = os:getenv("LAWSPEC_NETWORK_CONF"), true = os:putenv("LAWSPEC_NETWORK_CONF", Path),
    try
        #{identity := Identity, trusted := Trusted} = lawspec_beam_network_config:options(#{}),
        ?assertEqual(lawspec_beam_network_crypto:identity(seed(1)), Identity),
        ?assertEqual(#{Fingerprint => true}, Trusted),
        ?assertEqual(#{}, maps:get(trusted, lawspec_beam_network_config:options(#{identity => seed(3), trusted => []}))),
        ?assertError({lawspec, invalid_node_identity}, lawspec_beam_network_config:options(#{identity => <<>>, trusted => none})),
        ?assertError({lawspec, invalid_trusted_fingerprint}, lawspec_beam_network_config:options(#{identity => seed(3), trusted => [<<"bad">>]}))
    after case Previous of false -> os:unsetenv("LAWSPEC_NETWORK_CONF"); _ -> os:putenv("LAWSPEC_NETWORK_CONF", Previous) end end.
