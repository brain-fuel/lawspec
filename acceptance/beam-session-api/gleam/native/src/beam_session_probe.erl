%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(beam_session_probe).
-export([with_nodes/1, stop/1]).
with_nodes(Body) ->
    lawspec_beam_memory_network:with_network(#{seed => 728, loss => 0.15, duplicate => 0.25, delay => 0.001}, fun(Net) ->
        Nodes = [begin {ok, N} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, Name)), N
            end || Name <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>]],
        try apply(Body, Nodes) after lists:foreach(fun stop/1, Nodes) end
    end).
stop(Node) -> lawspec_beam_node:stop(Node), nil.
