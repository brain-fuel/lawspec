%% User-owned LawSpec adapter. Implement these functions.
-module(example_crypto).
-export([fingerprint/2, round_trip/2]).

-spec fingerprint(lawspec_abilities_lawspec_crypto:hash(), binary()) -> binary().

fingerprint(_HashHandler, _Bytes) ->
    erlang:error({not_implemented, <<"example.crypto::fingerprint">>}).

-spec round_trip(lawspec_abilities_lawspec_crypto:aead(), binary()) -> boolean().

round_trip(_AeadHandler, _Bytes) ->
    erlang:error({not_implemented, <<"example.crypto::roundTrip">>}).
