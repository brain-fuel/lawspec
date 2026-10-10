%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(example_session_types).
-export([native_probe/1, network_probe/1]).
-define(E, lawspec_session_example_session_types_exchange).
-define(S, lawspec_session_example_session_types_symbols).
-define(Z, lawspec_session_example_session_types_empty).
-define(A, lawspec_session_example_session_types_answer).
-define(P, lawspec_session_example_session_types_passing).

native_probe(ok) ->
    ?E:with_pair(fun(First, Second) ->
        Task = ?E:spawn_second(Second, fun(End) ->
            {{just, [1, 2, 3]}, Next} = ?E:second_receive_0(End),
            _ = ?E:second_send_1(Next, ok), ok
        end),
        Next = ?E:first_send_0(First, {just, [1, 2, 3]}),
        {ok, _} = ?E:first_receive_1(Next), ok = lawspec_beam_session_task:join(Task)
    end),
    ?S:with_pair(fun(First, Second) ->
        Identity = lawspec_beam_scalar:new_symbol(<<"session">>),
        _ = ?S:first_send_0(First, Identity), {Identity, _} = ?S:second_receive_0(Second)
    end),
    ?Z:with_pair(fun(_, _) -> true end).

network_probe(ok) -> beam_session_probe:with_nodes(fun(A, B, C, D) ->
    First = ?A:listen(A, <<"answer">>), Client = ?A:dial(C, ?A:address(First)),
    ClientNext = ?A:second_send_0(Client, 23),
    OnB = pass(First, A, B, <<"to-b">>), OnD = pass(OnB, B, D, <<"to-d">>),
    beam_session_probe:stop(A), beam_session_probe:stop(B),
    {23, Reply} = ?A:first_receive_0(OnD), _ = ?A:first_send_1(Reply, 46),
    {46, _} = ?A:second_receive_1(ClientNext),
    Exchange = ?E:listen(C, <<"data">>), Receiving = ?E:dial(D, ?E:address(Exchange)),
    E1 = ?E:first_send_0(Exchange, {just, [0, -7, 2147483647]}),
    {{just, [0, -7, 2147483647]}, E2} = ?E:second_receive_0(Receiving),
    _ = ?E:second_send_1(E2, ok), {ok, _} = ?E:first_receive_1(E1),
    ?A:with_pair(fun(Local, Peer) ->
        Remote = pass(Local, C, D, <<"relay">>), PeerNext = ?A:second_send_0(Peer, 42),
        {42, RemoteReply} = ?A:first_receive_0(Remote), _ = ?A:first_send_1(RemoteReply, 84),
        {84, _} = ?A:second_receive_1(PeerNext), true
    end)
end).
pass(End, A, B, Name) ->
    Giving = ?P:listen(A, Name), Taking = ?P:dial(B, ?P:address(Giving)),
    _ = ?P:first_send_0(Giving, End), {Moved, _} = ?P:second_receive_0(Taking), Moved.
