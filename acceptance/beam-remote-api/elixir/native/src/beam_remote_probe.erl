%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(beam_remote_probe).
-export([with_nodes/1, rejected/2]).
with_nodes(Body) ->
    lawspec_beam_memory_network:with_network(#{seed => 922, loss => 0.15, duplicate => 0.3, delay => 0.001}, fun(Net) ->
        {error, secure_network_not_available} = lawspec_beam_node:start(lawspec_beam_memory_network:transport(Net, <<"requires-import">>)),
        try lawspec_network:new_identity() of
            _ -> error(unexpected_crypto_without_import)
        catch error:{lawspec, {network, secure_network_not_available}} -> ok end,
        {ok, A} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"a">>)),
        {ok, B} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"b">>)),
        try Body(A, B) after lawspec_beam_node:stop(B), lawspec_beam_node:stop(A) end
    end).
rejected(Node, <<"sha3-256:", Digest:64/binary>>) ->
    [true] = lists:usort([lists:member(C, "0123456789abcdef") || C <- binary_to_list(Digest)]),
    Other = <<"sha3-256:", (binary:copy(<<"z">>, 64))/binary>>,
    Selector = lawspec_beam_values:encode([<<"text">>], Other, #{}),
    {3, _} = lawspec_beam_node:request(Node, <<"mem://b/definitions">>, <<"eval">>, <<Selector/binary, 14>>, 1000),
    true.
