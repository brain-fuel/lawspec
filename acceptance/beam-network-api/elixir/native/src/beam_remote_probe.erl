%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(beam_remote_probe).
-export([sealed/1, rejected/2]).
sealed(Net) ->
    Frames = lawspec_network:recorded(Net),
    Frames =/= [] andalso lists:all(fun(<<"LS", 1, _, _/binary>>) -> true; (_) -> false end, Frames).
rejected(Node, <<"sha3-256:", Digest:64/binary>>) ->
    [true] = lists:usort([lists:member(C, "0123456789abcdef") || C <- binary_to_list(Digest)]),
    Other = <<"sha3-256:", (binary:copy(<<"z">>, 64))/binary>>,
    Selector = lawspec_beam_values:encode([<<"text">>], Other, #{}),
    {3, _} = lawspec_beam_node:request(Node, <<"mem://b/definitions">>, <<"eval">>, <<Selector/binary, 14>>, 1000),
    true.
