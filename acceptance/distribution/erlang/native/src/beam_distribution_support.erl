%% Canonical vector checks use the shared descriptor codec and crypto bridge.
%% Session workers are joined, including when an adapter raises.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(beam_distribution_support).
-export([seed/1, encoded/4, round_trips/4, handshake_agrees/1,
    contains_frame/2, with_task/2]).

seed(Value) -> Value band 16#ffff.
samples(Text, Seed, Size, Count) ->
    {Table, Descriptor} = lawspec_beam_values:from_text(Text),
    {Values, _} = lists:mapfoldl(fun(_, State) ->
        lawspec_beam_values:generate(Descriptor, Table, State, Size)
    end, lawspec_beam_random:seed(Seed), lists:seq(1, Count)),
    {Table, Descriptor, Values}.
encoded(Text, Seed, Size, Count) ->
    {Table, Descriptor, Values} = samples(Text, Seed, Size, Count),
    [string:lowercase(binary:encode_hex(lawspec_beam_values:encode(Descriptor, Value, Table)))
        || Value <- Values].
round_trips(Text, Seed, Size, Count) ->
    {Table, Descriptor, Values} = samples(Text, Seed, Size, Count),
    lists:all(fun(Value) ->
        Bytes = lawspec_beam_values:encode(Descriptor, Value, Table),
        lawspec_beam_values:decode(Descriptor, Bytes, Table) =:= Value
    end, Values).

handshake_agrees(Vector) ->
    [I, R, K, S, A, B, C, N, F, H, W, ExpectedKey, ExpectedRecord] =
        binary:split(Vector, <<" ">>, [global]),
    X = fun binary:decode_hex/1,
    First = lawspec_beam_network_crypto:identity(X(I)),
    Second = lawspec_beam_network_crypto:identity(X(R)),
    {Kem, _} = lawspec_beam_crypto:mlkem_keypair(X(K)),
    Hello = lawspec_beam_network_crypto:hello(X(S), A, lawspec_beam_network_crypto:public(First), Kem),
    Welcome = lawspec_beam_network_crypto:welcome(X(S), B, lawspec_beam_network_crypto:public(Second), X(C), Hello),
    Key = lawspec_beam_network_crypto:key(lawspec_beam_crypto:mlkem_decapsulate(X(K), X(C)), Hello, Welcome),
    Record = lawspec_beam_network_crypto:seal(Key, X(S), 0, X(F), X(N)),
    {3, Session, 0, Sealed} = lawspec_beam_network_crypto:read(Record),
    X(H) =:= lawspec_beam_crypto:sha3_256(Hello) andalso
        X(W) =:= lawspec_beam_crypto:sha3_256(Welcome) andalso
        X(ExpectedKey) =:= Key andalso X(ExpectedRecord) =:= Record andalso
        {ok, X(F)} =:= lawspec_beam_network_crypto:open(Key, Session, 0, Sealed).

contains_frame(Network, Bytes) ->
    lists:any(fun(Frame) -> binary:match(Frame, Bytes) =/= nomatch end,
        lawspec_network:recorded(Network)).
with_task(Task, Body) ->
    try
        Result = Body(),
        _ = lawspec_beam_session_task:join(Task),
        Result
    after lawspec_beam_session_task:cancel(Task) end.
