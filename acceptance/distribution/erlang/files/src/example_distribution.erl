%% Native generated clients over secure memory, TCP and HTTP transports.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(example_distribution).
-export([encoded/4, round_trips/4, remote_shifted/1, open_tally/1, add/2,
    remote_adds/1, remote_doubling/1, remote_ledger/1, remote_handoff/1,
    remote_handoff_onward/1, sealed_on_the_wire/1, handshake_agrees/1]).

encoded(Text, Seed, Size, Count) -> beam_distribution_support:encoded(Text, Seed, Size, Count).
round_trips(Text, Seed, Size, Count) -> beam_distribution_support:round_trips(Text, Seed, Size, Count).
handshake_agrees(Vector) -> beam_distribution_support:handshake_agrees(Vector).
open_tally(ok) -> {tally, 0}.
add({tally, Count}, Value) -> After = Count + Value, {pair, After, {tally, After}}.

remote_shifted(Value) ->
    lawspec_network:with_memory(#{seed => beam_distribution_support:seed(Value), loss => 0.2, duplicate => 0.2}, fun(Net) ->
        lawspec_network:with_node(lawspec_network:memory_transport(Net, <<"here">>), fun(Here) ->
            lawspec_network:with_node(lawspec_network:memory_transport(Net, <<"there">>), fun(There) ->
                lawspec_remote:serve(There),
                lawspec_remote_example_distribution:shifted(Here, lawspec_network:address(There), Value)
            end)
        end)
    end).

remote_adds(Value) ->
    with_sockets(tcp, fun(Server, Client) ->
        lawspec_actor_example_distribution_tally:with_actor(fun(Actor) ->
            Address = lawspec_actor_example_distribution_tally:serve(Actor, Server, <<"tally">>),
            Tally = lawspec_actor_example_distribution_tally_remote:connect(Client, Address),
            _ = lawspec_actor_example_distribution_tally_remote:add(Tally, Value),
            lawspec_actor_example_distribution_tally_remote:add(Tally, Value)
        end)
    end).

remote_doubling(Value) ->
    with_sockets(http, fun(Server, Client) ->
        First = lawspec_session_example_distribution_doubling:listen(Server, <<"doubling">>),
        Second = lawspec_session_example_distribution_doubling:dial(Client,
            lawspec_session_example_distribution_doubling:address(First)),
        Worker = lawspec_session_example_distribution_doubling:spawn_second(Second, fun double/1),
        beam_distribution_support:with_task(Worker, fun() -> answer(First, Value) end)
    end).
double(End) ->
    {Value, Reply} = lawspec_session_example_distribution_doubling:second_receive_0(End),
    _ = lawspec_session_example_distribution_doubling:second_send_1(Reply, 2 * Value), ok.
answer(End, Value) ->
    Reply = lawspec_session_example_distribution_doubling:first_send_0(End, Value),
    {Result, _} = lawspec_session_example_distribution_doubling:first_receive_1(Reply), Result.

remote_ledger(Value) ->
    with_sockets(tcp, fun(Server, Client) ->
        Ledger = lawspec_mailbox_example_distribution_ledger:serve(Server, <<"ledger">>),
        try
            Sender = lawspec_mailbox_example_distribution_ledger:connect(Client,
                lawspec_mailbox_example_distribution_ledger:address(Ledger), 5000),
            ok = lawspec_mailbox_example_distribution_ledger:send_remote(Sender, Value),
            ok = lawspec_mailbox_example_distribution_ledger:send_remote(Sender, Value),
            Total = lawspec_mailbox_example_distribution_ledger:receive_value(Ledger) +
                lawspec_mailbox_example_distribution_ledger:receive_value(Ledger),
            nothing = lawspec_mailbox_example_distribution_ledger:receive_within(Ledger, 20000),
            Total
        after lawspec_mailbox_example_distribution_ledger:stop(Ledger) end
    end).

remote_handoff(Value) ->
    with_sockets(tcp, fun(Here, There) ->
        lawspec_session_example_distribution_doubling:with_pair(fun(First, Second) ->
            Worker = lawspec_session_example_distribution_doubling:spawn_second(Second, fun double/1),
            beam_distribution_support:with_task(Worker, fun() ->
                Giving = lawspec_session_example_distribution_handoff:listen(Here, <<"handoff">>),
                Taking = lawspec_session_example_distribution_handoff:dial(There,
                    lawspec_session_example_distribution_handoff:address(Giving)),
                _ = lawspec_session_example_distribution_handoff:first_send_0(Giving, First),
                {End, _} = lawspec_session_example_distribution_handoff:second_receive_0(Taking),
                answer(End, Value)
            end)
        end)
    end).

remote_handoff_onward(Value) ->
    lawspec_network:with_memory(#{seed => beam_distribution_support:seed(Value), loss => 0.1,
        duplicate => 0.1, delay => 0.005}, fun(Net) ->
        with_memory_nodes(Net, [<<"a">>, <<"b">>, <<"c">>, <<"d">>], fun([A, B, C, D]) ->
            First = lawspec_session_example_distribution_answering:listen(A, <<"answering">>),
            Peer = lawspec_session_example_distribution_answering:dial(C,
                lawspec_session_example_distribution_answering:address(First)),
            Second = lawspec_session_example_distribution_answering:second_send_0(Peer, Value),
            GivingB = lawspec_session_example_distribution_passing:listen(A, <<"to-b">>),
            TakingB = lawspec_session_example_distribution_passing:dial(B,
                lawspec_session_example_distribution_passing:address(GivingB)),
            _ = lawspec_session_example_distribution_passing:first_send_0(GivingB, First),
            {Moved, _} = lawspec_session_example_distribution_passing:second_receive_0(TakingB),
            GivingD = lawspec_session_example_distribution_passing:listen(B, <<"to-d">>),
            TakingD = lawspec_session_example_distribution_passing:dial(D,
                lawspec_session_example_distribution_passing:address(GivingD)),
            _ = lawspec_session_example_distribution_passing:first_send_0(GivingD, Moved),
            {End, _} = lawspec_session_example_distribution_passing:second_receive_0(TakingD),
            ok = lawspec_network:close(A), ok = lawspec_network:close(B),
            {Input, Reply} = lawspec_session_example_distribution_answering:first_receive_0(End),
            _ = lawspec_session_example_distribution_answering:first_send_1(Reply, 2 * Input),
            {Result, _} = lawspec_session_example_distribution_answering:second_receive_1(Second), Result
        end)
    end).
with_memory_nodes(_, [], Body) -> Body([]);
with_memory_nodes(Net, [Name | Names], Body) ->
    lawspec_network:with_node(lawspec_network:memory_transport(Net, Name), fun(Node) ->
        with_memory_nodes(Net, Names, fun(Nodes) -> Body([Node | Nodes]) end)
    end).

sealed_on_the_wire(Value) ->
    Digest = lawspec_remote:digest(<<"example.distribution::shifted">>),
    lists:all(fun(Insecure) ->
        lawspec_network:with_memory(#{seed => beam_distribution_support:seed(Value), record => true}, fun(Net) ->
            Make = case Insecure of
                true -> fun lawspec_network:insecure_memory_transport_for_tests/2;
                false -> fun lawspec_network:memory_transport/2
            end,
            lawspec_network:with_node(Make(Net, <<"here">>), fun(Here) ->
                lawspec_network:with_node(Make(Net, <<"there">>), fun(There) ->
                    lawspec_remote:serve(There),
                    lawspec_remote_example_distribution:shifted(Here, lawspec_network:address(There), Value) =:= Value + 1000
                        andalso beam_distribution_support:contains_frame(Net, Digest) =:= Insecure
                end)
            end)
        end)
    end, [false, true]).

with_sockets(Kind, Body) ->
    Transport = case Kind of
        tcp -> lawspec_network:tcp(<<"127.0.0.1">>, 0);
        http -> lawspec_network:http(<<"127.0.0.1">>, 0)
    end,
    lawspec_network:with_node(Transport, fun(Server) ->
        lawspec_network:with_node(Transport, fun(Client) -> Body(Server, Client) end)
    end).
