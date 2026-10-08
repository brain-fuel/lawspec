-module(example_crypto_context).
-export([native_probe/1]).

native_probe(ok) ->
    Hash = lawspec_crypto:hash_handler(),
    Exchange = lawspec_crypto:key_exchange_handler(),
    Signature = lawspec_crypto:signature_handler(),
    Slh = lawspec_crypto:slh_dsa_signature_handler(),
    Aead = lawspec_crypto:aead_handler(),
    #{sha3 := Sha3, shake := Shake} = Hash,
    {digest, Digest} = Sha3(<<"LawSpec">>),
    #{exchange_key_pair := ExchangeKeyPair} = Exchange,
    {exchange_key_pair, {exchange_public_key, Public}, {exchange_secret_key, Secret}} = ExchangeKeyPair(),
    #{signing_key_pair := SigningKeyPair} = Signature,
    {signing_key_pair, {verifying_key, VerifyKey}, {signing_key, SigningKey}} = SigningKeyPair(),
    #{signing_key_pair := SlhKeyPair} = Slh,
    {signing_key_pair, {verifying_key, SlhPublic}, {signing_key, SlhPrivate}} = SlhKeyPair(),
    Message = <<0, 255, 128>>,
    Context = <<"native">>,
    Good = lists:all(fun(Signer) ->
        example_crypto_context_definitions:handshake(Exchange, Signer, Aead, Message, Context) =:= {just, Message}
    end, [Signature, Slh]),
    byte_size(Digest) =:= 32 andalso byte_size(Shake(Message, 13)) =:= 13 andalso
        byte_size(Public) =:= 1184 andalso byte_size(Secret) =:= 64 andalso
        byte_size(VerifyKey) =:= 1952 andalso byte_size(SigningKey) =:= 32 andalso
        byte_size(SlhPublic) =:= 32 andalso byte_size(SlhPrivate) =:= 64 andalso Good.
