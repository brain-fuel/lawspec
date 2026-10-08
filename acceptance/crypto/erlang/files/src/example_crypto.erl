-module(example_crypto).
-export([fingerprint/2, round_trip/2]).

fingerprint(#{sha3 := Sha3}, Bytes) ->
    {digest, Digest} = Sha3(Bytes),
    binary:part(Digest, 0, 8).

round_trip(#{aead_key := Make, seal := Seal, unseal := Unseal}, Message) ->
    Key = Make(),
    Associated = <<"round trip">>,
    Unseal(Key, Seal(Key, Message, Associated), Associated) =:= {just, Message}.
