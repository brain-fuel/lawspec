%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(beam_remote_probe).
-export([with_nodes/1, stop/1]).
with_nodes(Body) ->
    lawspec_beam_memory_network:with_network(#{seed => 922, loss => 0.15, duplicate => 0.3, delay => 0.001}, fun(Net) ->
        {ok, A} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"a">>)),
        {ok, B} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"b">>)),
        try Body(A, B) after lawspec_beam_node:stop(B), lawspec_beam_node:stop(A) end
    end).
stop(Node) -> lawspec_beam_node:stop(Node), nil.
