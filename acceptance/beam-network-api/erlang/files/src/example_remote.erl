%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(example_remote).
-export([offset_handler/0, native_probe/1]).
offset_handler() -> #{shift => fun(N) -> N + 1000 end}.
native_probe(ok) ->
    Identity = lawspec_network:identity_from_seed(<<0:256>>), Other = lawspec_network:new_identity(),
    Options = lawspec_network:with_trusted(lawspec_network:with_identity(lawspec_network:options(), Identity),
        [lawspec_network:fingerprint(Other)]),
    OtherOptions = lawspec_network:with_trusted(lawspec_network:with_identity(lawspec_network:options(), Other),
        [lawspec_network:fingerprint(Identity)]),
    lawspec_network:with_memory(#{record => true, seed => 922, loss => 0.15, duplicate => 0.3, delay => 0.001}, fun(Net) ->
      lawspec_network:with_node(lawspec_network:memory_transport(Net, <<"a">>), Options, fun(A) ->
       lawspec_network:with_node(lawspec_network:memory_transport(Net, <<"b">>), OtherOptions, fun(B) ->
        Fingerprint = lawspec_network:fingerprint(Identity), Fingerprint = lawspec_network:node_fingerprint(A),
        <<"mem://b">> = lawspec_network:address(B),
        <<"mem://b/definitions">> = lawspec_remote:serve(B, #{shift => fun(N) -> N + 40 end}),
        47 = lawspec_remote_example_remote:shifted(A, <<"mem://b">>, 7),
        48 = lawspec_remote_example_remote:shifted_with_timeout(A, <<"mem://b">>, 1000, 8),
        P = {parcel, 42, {just, <<"sent">>}},
        P = lawspec_remote_example_remote:parcel(A, <<"mem://b">>, P),
        ok = lawspec_remote_example_remote:nothing(A, <<"mem://b">>, ok),
        beam_remote_probe:rejected(A, lawspec_remote:digest(<<"example.remote::shifted">>)) andalso beam_remote_probe:sealed(Net)
       end)
      end)
    end).
