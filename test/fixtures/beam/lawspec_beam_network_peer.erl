%% @doc A packet conduit for the independent Python interoperability check.
%% Only the transport crosses stdin/stdout; the real node owns crypto and RPC.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_network_peer).
-export([run/1]).
run(Mode) ->
    logger:set_primary_config(level, none),
    {ok, Net} = lawspec_beam_memory_network:start(#{}),
    ok = lawspec_beam_memory_network:register(Net, <<"mem://python">>, self()),
    {ok, Node} = lawspec_beam_node:start(lawspec_beam_memory_network:transport(Net, <<"beam">>),
        #{identity => binary:copy(<<2>>, 32), trusted => none}),
    lawspec_beam_node:register_handler(Node, <<"echo">>, fun(#{payload := Bytes}) -> {0, Bytes} end),
    Parent = self(), Reader = spawn_link(fun() -> input(Parent) end),
    case Mode of
        initiator -> lawspec_beam_node:request_async(Node, <<"mem://python/echo">>, <<"call">>, <<"from beam">>, 5000);
        responder -> ok
    end,
    try loop(Net, Node) after unlink(Reader), exit(Reader, kill), lawspec_beam_node:stop(Node), lawspec_beam_memory_network:stop(Net) end,
    halt(0).
input(Parent) -> case io:get_line("") of
    eof -> Parent ! eof;
    Line -> Parent ! {input, base64:decode(string:trim(Line))}, input(Parent)
end.
loop(Net, Node) -> receive
    {input, Bytes} -> ok = lawspec_beam_memory_network:send(Net, <<"mem://python">>, <<"mem://beam">>, Bytes), loop(Net, Node);
    {lawspec_network, Net, _, Bytes} -> io:format("~s~n", [base64:encode(Bytes)]), loop(Net, Node);
    {lawspec_reply, Node, _, {ok, {0, <<"from python">>}}} -> io:format("done~n"), ok;
    eof -> ok
after 7000 -> error(peer_timed_out)
end.
