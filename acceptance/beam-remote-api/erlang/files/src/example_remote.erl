%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(example_remote).
-export([offset_handler/0, native_probe/1]).
offset_handler() -> #{shift => fun(N) -> N + 1000 end}.
native_probe(ok) ->
    beam_remote_probe:with_nodes(fun(A, B) ->
        <<"mem://b/definitions">> = lawspec_remote:serve(B, #{shift => fun(N) -> N + 40 end}),
        47 = lawspec_remote_example_remote:shifted(A, <<"mem://b">>, 7),
        48 = lawspec_remote_example_remote:shifted_with_timeout(A, <<"mem://b">>, 1000, 8),
        P = {parcel, 42, {just, <<"sent">>}},
        P = lawspec_remote_example_remote:parcel(A, <<"mem://b">>, P),
        ok = lawspec_remote_example_remote:nothing(A, <<"mem://b">>, ok),
        beam_remote_probe:rejected(A, lawspec_remote:digest(<<"example.remote::shifted">>))
    end).
