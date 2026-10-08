%% @doc Cryptographic primitives backed by OTP's crypto application.
%% Logical ability values are converted by the generated native interfaces.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_crypto).
-export([handler/1, slh_dsa_signature_handler/0, sha3_256/1, shake256/2, derive_aead_key/2,
    mlkem_keypair/1, mlkem_encapsulate/1, mlkem_decapsulate/2, mlkem_decapsulate_expanded/2,
    mldsa_public/1, mldsa_sign/2, mldsa_sign/4, mldsa_verify/3, mldsa_verify/4,
    slh_keypair/0, slh_keypair/1, slh_sign/2, slh_sign/3, slh_verify/3, slh_verify/4,
    aes256_gcm_encrypt/4, aes256_gcm_decrypt/4, seal/3, unseal/3]).

handler(<<"lawspec.crypto::ability::Hash">>) ->
    lawspec_beam_effects:stateless(#{
        <<"sha3">> => fun(_, [Message]) -> wrap(<<"Digest">>, sha3_256(Message)) end,
        <<"shake">> => fun(_, [Message, Count]) -> shake256(Message, Count) end});
handler(<<"lawspec.crypto::ability::KeyExchange">>) ->
    lawspec_beam_effects:stateless(#{
        <<"exchangeKeyPair">> => fun(_, []) ->
            {Public, Secret} = mlkem_keypair(crypto:strong_rand_bytes(64)),
            pair(<<"ExchangeKeyPair">>, wrap(<<"ExchangePublicKey">>, Public), wrap(<<"ExchangeSecretKey">>, Secret))
        end,
        <<"encapsulate">> => fun(_, [Public]) ->
            {Ciphertext, Shared} = mlkem_encapsulate(unwrap(<<"ExchangePublicKey">>, Public)),
            pair(<<"Encapsulated">>, wrap(<<"Ciphertext">>, Ciphertext), wrap(<<"SharedSecret">>, Shared))
        end,
        <<"decapsulate">> => fun(_, [Secret, Ciphertext]) ->
            wrap(<<"SharedSecret">>, mlkem_decapsulate(unwrap(<<"ExchangeSecretKey">>, Secret), unwrap(<<"Ciphertext">>, Ciphertext)))
        end});
handler(<<"lawspec.crypto::ability::Signature">>) ->
    signature_handler(fun() -> Seed = crypto:strong_rand_bytes(32), {mldsa_public(Seed), Seed} end,
        fun mldsa_sign/2, fun mldsa_verify/3);
handler(<<"lawspec.crypto::ability::Aead">>) ->
    lawspec_beam_effects:stateless(#{
        <<"aeadKey">> => fun(_, []) -> wrap(<<"AeadKey">>, crypto:strong_rand_bytes(32)) end,
        <<"deriveAeadKey">> => fun(_, [Secret, Context]) ->
            wrap(<<"AeadKey">>, derive_aead_key(unwrap(<<"SharedSecret">>, Secret), Context))
        end,
        <<"seal">> => fun(_, [Key, Message, Associated]) ->
            wrap(<<"Sealed">>, seal(unwrap(<<"AeadKey">>, Key), Message, Associated))
        end,
        <<"unseal">> => fun(_, [Key, Sealed, Associated]) ->
            case unseal(unwrap(<<"AeadKey">>, Key), unwrap(<<"Sealed">>, Sealed), Associated) of
                {ok, Message} -> {ls_data, <<"Maybe::Just">>, [Message]};
                error -> {ls_data, <<"Maybe::Nothing">>, []}
            end
        end}).

slh_dsa_signature_handler() -> signature_handler(fun slh_keypair/0, fun slh_sign/2, fun slh_verify/3).

signature_handler(Make, Sign, Verify) ->
    lawspec_beam_effects:stateless(#{
        <<"signingKeyPair">> => fun(_, []) ->
            {Public, Secret} = Make(),
            pair(<<"SigningKeyPair">>, wrap(<<"VerifyingKey">>, Public), wrap(<<"SigningKey">>, Secret))
        end,
        <<"sign">> => fun(_, [Secret, Message]) ->
            wrap(<<"SignatureBytes">>, Sign(unwrap(<<"SigningKey">>, Secret), Message))
        end,
        <<"verify">> => fun(_, [Public, Message, Signature]) ->
            Verify(unwrap(<<"VerifyingKey">>, Public), Message, unwrap(<<"SignatureBytes">>, Signature))
        end}).

pair(Name, First, Second) -> {ls_data, <<"lawspec.crypto::type::", Name/binary, "::", Name/binary>>, [First, Second]}.
wrap(Name, Bytes) -> {ls_data, <<"lawspec.crypto::type::", Name/binary, "::", Name/binary>>, [Bytes]}.
unwrap(Name, {ls_data, Tag, [Bytes]}) ->
    Expected = <<"lawspec.crypto::type::", Name/binary, "::", Name/binary>>,
    Expected = Tag,
    Bytes.

sha3_256(Message) -> crypto:hash(sha3_256, Message).

%% OTP's XOF length is in bits; LawSpec's operation counts bytes.
shake256(_, Count) when Count =< 0 -> <<>>;
shake256(Message, Count) -> crypto:hash_xof(shake256, Message, Count * 8).

derive_aead_key(Secret, Context) -> shake256([Secret, Context], 32).

%% LawSpec stores the FIPS key-generation seeds, not OTP's expanded private
%% encodings. Expand at the boundary without changing the portable wire format.
mlkem_keypair(Seed) ->
    {Public, _} = lawspec_beam_crypto_native:expand(mlkem768, Seed),
    {Public, Seed}.

mlkem_encapsulate(Public) ->
    {Shared, Ciphertext} = crypto:encapsulate_key(mlkem768, Public),
    {Ciphertext, Shared}.

mlkem_decapsulate(Seed, Ciphertext) ->
    {_, Private} = lawspec_beam_crypto_native:expand(mlkem768, Seed),
    mlkem_decapsulate_expanded(Private, Ciphertext).

mlkem_decapsulate_expanded(Private, Ciphertext) -> crypto:decapsulate_key(mlkem768, Private, Ciphertext).

mldsa_public(Seed) ->
    {Public, _} = lawspec_beam_crypto_native:expand(mldsa65, Seed),
    Public.

mldsa_sign(Seed, Message) when byte_size(Seed) =:= 32 -> crypto:sign(mldsa65, none, Message, {seed, Seed}).
mldsa_sign(Seed, Message, <<>>, false) -> mldsa_sign(Seed, Message);
mldsa_sign(Seed, Message, Context, Deterministic) ->
    lawspec_beam_crypto_native:sign_context(mldsa65, Seed, Message, Context, Deterministic).

mldsa_verify(Public, Message, Signature) -> mldsa_verify(Public, Message, Signature, <<>>).
mldsa_verify(Public, Message, Signature, Context) -> verify(mldsa65, 1952, 3309, Public, Message, Signature, Context).

slh_keypair() -> crypto:generate_key(slh_dsa_shake_128f, []).
slh_keypair(Seed) -> lawspec_beam_crypto_native:expand(slh_dsa_shake_128f, Seed).
slh_sign(Private, Message) when byte_size(Private) =:= 64 -> crypto:sign(slh_dsa_shake_128f, none, Message, Private).
slh_sign(Private, Message, <<>>) -> slh_sign(Private, Message);
slh_sign(Private, Message, Context) ->
    lawspec_beam_crypto_native:sign_context(slh_dsa_shake_128f, Private, Message, Context, false).
slh_verify(Public, Message, Signature) -> slh_verify(Public, Message, Signature, <<>>).
slh_verify(Public, Message, Signature, Context) -> verify(slh_dsa_shake_128f, 32, 17088, Public, Message, Signature, Context).

verify(Algorithm, PublicSize, SignatureSize, Public, Message, Signature, Context)
        when byte_size(Public) =:= PublicSize, byte_size(Signature) =:= SignatureSize, byte_size(Context) =< 255 ->
    case Context of
        <<>> -> crypto:verify(Algorithm, none, Message, Signature, Public);
        _ -> lawspec_beam_crypto_native:verify_context(Algorithm, Public, Message, Signature, Context)
    end;
verify(_, _, _, _, _, _, _) -> false.

aes256_gcm_encrypt(Key, Nonce, Message, Associated)
        when byte_size(Key) =:= 32, byte_size(Nonce) =:= 12 ->
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce,
        Message, Associated, 16, true),
    <<Ciphertext/binary, Tag/binary>>.

aes256_gcm_decrypt(Key, Nonce, Sealed, Associated)
        when byte_size(Key) =:= 32, byte_size(Nonce) =:= 12, byte_size(Sealed) >= 16 ->
    Size = byte_size(Sealed) - 16,
    <<Ciphertext:Size/binary, Tag:16/binary>> = Sealed,
    case crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Ciphertext, Associated, Tag, false) of
        error -> error;
        Plaintext -> {ok, Plaintext}
    end;
aes256_gcm_decrypt(_, _, _, _) -> error.

seal(Key, Message, Associated) ->
    Nonce = crypto:strong_rand_bytes(12),
    Sealed = aes256_gcm_encrypt(Key, Nonce, Message, Associated),
    <<Nonce/binary, Sealed/binary>>.

unseal(Key, <<Nonce:12/binary, Sealed/binary>>, Associated) ->
    aes256_gcm_decrypt(Key, Nonce, Sealed, Associated);
unseal(_, _, _) -> error.
