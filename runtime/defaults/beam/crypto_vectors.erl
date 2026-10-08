%% NIST primitive checks shared by the three native test frameworks.
%% Vector provenance: docs/reference/language/cryptography.md.
%% ref:DEC-tests-cite-requirements
-module(lawspec_beam_crypto_vectors).
-export([check/1]).

check(<<"sha3-256">> = Kind) -> each(Kind, fun([Message, Expected]) ->
    ExpectedBytes = hex(Expected), ExpectedBytes = lawspec_beam_crypto:sha3_256(hex(Message)) end);
check(<<"shake256">> = Kind) -> each(Kind, fun([Message, Count, Expected]) ->
    ExpectedBytes = hex(Expected), ExpectedBytes = lawspec_beam_crypto:shake256(hex(Message), binary_to_integer(Count)) end);
check(<<"aes-256-gcm">> = Kind) -> each(Kind, fun(Row) ->
    [Key, Nonce, Message, Associated, Ciphertext, Tag] = lists:map(fun hex/1, Row),
    Expected = <<Ciphertext/binary, Tag/binary>>,
    Expected = lawspec_beam_crypto:aes256_gcm_encrypt(Key, Nonce, Message, Associated),
    {ok, Message} = lawspec_beam_crypto:aes256_gcm_decrypt(Key, Nonce, Expected, Associated),
    error = lawspec_beam_crypto:aes256_gcm_decrypt(Key, Nonce, flip(Expected), Associated) end);
check(<<"mlkem768-keygen">> = Kind) -> each(Kind, fun([D, Z, PublicDigest, PrivateDigest]) ->
    Seed = hex(<<D/binary, Z/binary>>),
    {Public, Private} = lawspec_beam_crypto_native:expand(mlkem768, Seed),
    PublicDigest = digest(Public), PrivateDigest = digest(Private),
    {Public, Seed} = lawspec_beam_crypto:mlkem_keypair(Seed) end);
check(<<"mlkem768-encaps">> = Kind) -> each(Kind, fun(Row) ->
    [Public, Message, Ciphertext, Shared] = lists:map(fun hex/1, Row),
    {Ciphertext, Shared} = lawspec_beam_crypto_native:encapsulate_test(Public, Message) end);
check(<<"mlkem768-decaps">> = Kind) -> each(Kind, fun(Row) ->
    [Private, Ciphertext, Shared] = lists:map(fun hex/1, Row),
    Shared = lawspec_beam_crypto:mlkem_decapsulate_expanded(Private, Ciphertext) end);
check(<<"mlkem768-decaps-seed">> = Kind) -> each(Kind, fun(Row) ->
    [Seed, Ciphertext, Shared] = lists:map(fun hex/1, Row),
    Shared = lawspec_beam_crypto:mlkem_decapsulate(Seed, Ciphertext) end);
check(<<"mldsa65-keygen">> = Kind) -> each(Kind, fun([Seed, PublicDigest, PrivateDigest]) ->
    {Public, Private} = lawspec_beam_crypto_native:expand(mldsa65, hex(Seed)),
    PublicDigest = digest(Public), PrivateDigest = digest(Private),
    Public = lawspec_beam_crypto:mldsa_public(hex(Seed)) end);
check(<<"mldsa65-verify">> = Kind) -> each(Kind, fun([Public, Message, Context, Signature, Passed]) ->
    Expected = Passed =:= <<"true">>,
    Expected = lawspec_beam_crypto:mldsa_verify(hex(Public), hex(Message), hex(Signature), hex(Context)) end);
check(<<"mldsa65-sign-seed">> = Kind) -> each(Kind, fun(Row) ->
    [Seed, Message, Signature] = lists:map(fun hex/1, Row),
    Signature = lawspec_beam_crypto:mldsa_sign(Seed, Message, <<>>, true),
    Public = lawspec_beam_crypto:mldsa_public(Seed),
    true = lawspec_beam_crypto:mldsa_verify(Public, Message, Signature),
    false = lawspec_beam_crypto:mldsa_verify(Public, flip(Message), Signature) end);
check(<<"slhdsa128f-keygen">> = Kind) -> each(Kind, fun([S, P, X, PublicHex, PrivateDigest]) ->
    {Public, Private} = lawspec_beam_crypto:slh_keypair(hex(<<S/binary, P/binary, X/binary>>)),
    Public = hex(PublicHex), PrivateDigest = digest(Private),
    Signature = lawspec_beam_crypto:slh_sign(Private, <<"LawSpec">>),
    true = lawspec_beam_crypto:slh_verify(Public, <<"LawSpec">>, Signature),
    false = lawspec_beam_crypto:slh_verify(Public, <<"LawSpeC">>, Signature) end);
check(<<"slhdsa128f-verify">> = Kind) -> each(Kind, fun([Public, Message, Context, Signature, Passed]) ->
    Expected = Passed =:= <<"true">>,
    Expected = lawspec_beam_crypto:slh_verify(hex(Public), hex(Message), hex(Signature), hex(Context)),
    false = lawspec_beam_crypto:slh_verify(hex(Public), flip(hex(Message)), hex(Signature), hex(Context)) end).

each(Kind, Check) ->
    Rows = [Fields || Line <- binary:split(vector_text(), <<"\n">>, [global]),
        [Tag | Fields] <- [binary:split(Line, <<" ">>, [global, trim_all])], Tag =:= Kind],
    case Rows of [] -> error({missing_crypto_vectors, Kind}); _ -> ok end,
    lists:foreach(Check, Rows),
    nil.

hex(<<"-">>) -> <<>>;
hex(Text) -> binary:decode_hex(Text).
digest(Bytes) -> binary:encode_hex(lawspec_beam_crypto:sha3_256(Bytes), lowercase).
flip(<<First, Rest/binary>>) -> <<(First bxor 1), Rest/binary>>.
vector_text() -> @@VECTORS@@.
