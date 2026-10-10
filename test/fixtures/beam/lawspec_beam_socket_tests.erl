%% Real loopback conformance. These tests must fail when sockets cannot be
%% opened; parser-only checks are not a substitute for transport evidence.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
-module(lawspec_beam_socket_tests).
-include_lib("eunit/include/eunit.hrl").

secure_socket_test_() ->
    [{atom_to_list(Kind) ++ " " ++ Name, {timeout, 15, fun() -> Body(Kind) end}} || Kind <- [tcp, http],
        {Name, Body} <- [{"concurrent requests and joined shutdown", fun requests/1},
            {"killed node closes listener and workers", fun killed/1},
            {"unresponsive peer cannot block another peer", fun unresponsive/1},
            {"creating process owns its node", fun creator/1}]].

transport(tcp, Port) -> lawspec_network:tcp(<<"127.0.0.1">>, Port);
transport(http, Port) -> lawspec_network:http(<<"127.0.0.1">>, Port).
with_nodes(Kind, Body) ->
    lawspec_network:with_node(transport(Kind, 0), fun(A) ->
        lawspec_network:with_node(transport(Kind, 0), fun(B) -> Body(A, B) end)
    end).
echo(Node) -> lawspec_beam_node:register_handler(Node, <<"echo">>, fun(#{payload := Bytes}) -> {0, Bytes} end).
packet_node(Node) ->
    #{connection := #{pid := Layer}} = sys:get_state(Node),
    #{connection := #{pid := Raw}} = sys:get_state(Layer), {Layer, Raw}.
descendants(Node) ->
    {Layer, Raw} = packet_node(Node),
    #{workers := Workers, acceptor := Acceptor} = sys:get_state(Raw), [Node, Layer, Raw, Acceptor | maps:keys(Workers)].
gone(Pid) ->
    Ref = monitor(process, Pid), receive {'DOWN', Ref, process, Pid, _} -> ok
    after 2000 -> error({process_leaked, Pid}) end.
ask(Node, Address, Bytes) -> lawspec_beam_node:request(Node, Address, <<"call">>, Bytes, 5000).

requests(Kind) -> with_nodes(Kind, fun(A, B) ->
    Count = atomics:new(1, []),
    Address = lawspec_beam_node:register_handler(B, <<"echo">>, fun(#{payload := Bytes}) -> atomics:add(Count, 1, 1), {0, Bytes} end),
    Workers = [spawn_monitor(fun() -> ?assertEqual({0, <<I>>}, ask(A, Address, <<I>>)) end) || I <- lists:seq(1, 30)],
    lists:foreach(fun({Pid, Ref}) -> receive {'DOWN', Ref, process, Pid, Why} -> ?assertEqual(normal, Why)
        after 6000 -> exit(Pid, kill), error(request_stuck) end end, Workers),
    ?assertEqual(30, atomics:get(Count, 1)),
    Children = descendants(A), ok = lawspec_network:close(A),
    lists:foreach(fun(Pid) -> ?assertNot(is_process_alive(Pid)) end, Children)
end).

killed(Kind) -> with_nodes(Kind, fun(A, B) ->
    ?assertEqual({0, <<"hello">>}, ask(A, echo(B), <<"hello">>)),
    {ok, _, Port} = lawspec_beam_socket_protocol:endpoint(Kind, lawspec_network:address(A)),
    Children = descendants(A), exit(A, kill), lists:foreach(fun gone/1, Children),
    lawspec_network:with_node(transport(Kind, Port), fun(Replacement) ->
        ?assertEqual(lawspec_beam_socket_protocol:address(Kind, <<"127.0.0.1">>, Port), lawspec_network:address(Replacement))
    end)
end).

unresponsive(Kind) -> with_nodes(Kind, fun(A, B) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
    try
        {ok, {_, Port}} = inet:sockname(Listener),
        Peer = lawspec_beam_socket_protocol:address(Kind, <<"127.0.0.1">>, Port),
        {Ticket, _} = lawspec_beam_node:request_async(A, <<Peer/binary, "/echo">>, <<"call">>, <<"blocked">>, 8000),
        Start = erlang:monotonic_time(millisecond),
        ?assertEqual({0, <<"other">>}, ask(A, echo(B), <<"other">>)),
        ?assert(erlang:monotonic_time(millisecond) - Start < 2000),
        lawspec_beam_node:cancel(A, Ticket), Children = descendants(A),
        Closing = erlang:monotonic_time(millisecond), ok = lawspec_network:close(A),
        ?assert(erlang:monotonic_time(millisecond) - Closing < 2000),
        lists:foreach(fun(Pid) -> ?assertNot(is_process_alive(Pid)) end, Children)
    after gen_tcp:close(Listener) end
end).

creator(Kind) ->
    Parent = self(), {Owner, Ref} = spawn_monitor(fun() ->
        Node = lawspec_network:open(transport(Kind, 0)), Parent ! {opened, self(), Node}, receive finish -> ok end
    end),
    receive
        {opened, Owner, Node} ->
            Children = descendants(Node), exit(Owner, kill),
            receive {'DOWN', Ref, process, Owner, killed} -> ok end,
            lists:foreach(fun gone/1, Children);
        {'DOWN', Ref, process, Owner, Reason} -> error({node_open_failed, Reason})
    after 6000 -> exit(Owner, kill), error(node_open_stuck) end.

tcp_length_prefix_handles_split_and_coalesced_records_test() ->
    {ok, Raw} = lawspec_beam_socket_transport:start(transport(tcp, 0), self()),
    {ok, Host, Port} = lawspec_beam_socket_protocol:endpoint(tcp, lawspec_beam_socket_transport:address(Raw)),
    try
        {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}]),
        try
            ok = gen_tcp:send(Socket, <<0,0>>), no_packet(Raw),
            ok = gen_tcp:send(Socket, <<0,3,1>>), no_packet(Raw),
            ok = gen_tcp:send(Socket, <<2,3,2:32/unsigned-big,4,5>>),
            ?assertEqual(<<1,2,3>>, packet(Raw)), ?assertEqual(<<4,5>>, packet(Raw)),
            ok = gen_tcp:send(Socket, <<67108865:32/unsigned-big>>),
            ?assertEqual({error, closed}, gen_tcp:recv(Socket, 0, 2000)), no_packet(Raw)
        after gen_tcp:close(Socket) end
    after lawspec_beam_socket_transport:stop(Raw) end.

http_delivers_only_complete_valid_post_and_returns_receipt_test() ->
    {ok, Raw} = lawspec_beam_socket_transport:start(transport(http, 0), self()),
    Address = lawspec_beam_socket_transport:address(Raw),
    {ok, Host, Port} = lawspec_beam_socket_protocol:endpoint(http, Address),
    try
        {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}]),
        try
            Request = iolist_to_binary(lawspec_beam_socket_protocol:request(Address, <<1,2,3>>)),
            Size = byte_size(Request) - 2, <<First:Size/binary, Last/binary>> = Request,
            ok = gen_tcp:send(Socket, First), no_packet(Raw), ok = gen_tcp:send(Socket, Last),
            ?assertEqual(<<1,2,3>>, packet(Raw)),
            Reply = response(Socket, <<>>),
            ?assertEqual(ok, lawspec_beam_socket_protocol:reply(Reply))
        after gen_tcp:close(Socket) end,
        {ok, Bad} = gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}]),
        try
            ok = gen_tcp:send(Bad, <<"POST /wrong HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc">>),
            <<"HTTP/1.1 404", _/binary>> = response(Bad, <<>>), no_packet(Raw)
        after gen_tcp:close(Bad) end
    after lawspec_beam_socket_transport:stop(Raw) end.
packet(Raw) -> receive {lawspec_network, Raw, unknown, Bytes} -> Bytes after 2000 -> error(packet_missing) end.
no_packet(Raw) -> receive {lawspec_network, Raw, _, _} -> error(unexpected_packet) after 20 -> ok end.
response(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch -> {ok, Bytes} = gen_tcp:recv(Socket, 0, 2000), response(Socket, <<Acc/binary, Bytes/binary>>);
        _ -> Acc
    end.
