%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(beam_mailbox_probe).
-export([with_nodes/1, rejects/1]).
rejects(Body) -> try Body(), false catch error:{lawspec, _} -> true end.
with_nodes(Body) ->
    lawspec_beam_memory_network:with_network(#{seed => 820, loss => 0.2, duplicate => 0.4, delay => 0.002}, fun(Net) ->
        {ok, A} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"a">>)),
        {ok, B} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"b">>)),
        try Body(A, B) after lawspec_beam_node:stop(B), lawspec_beam_node:stop(A) end
    end).
