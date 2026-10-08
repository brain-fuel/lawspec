%% @doc Known-answer and malformed-input checks for the OTP crypto boundary.
%% The vector provenance is recorded in runtime/defaults/vectors.txt.
%% ref:DEC-tests-cite-requirements ref:DEC-typed-core-boundary
-module(lawspec_beam_crypto_tests).
-include_lib("eunit/include/eunit.hrl").

vectors(Kind) ->
    {ok, Text} = file:read_file("runtime/defaults/vectors.txt"),
    Rows = [Fields || Line <- binary:split(Text, <<"\n">>, [global]),
        [Tag | Fields] <- [binary:split(Line, <<" ">>, [global, trim_all])], Tag =:= Kind],
    ?assertNotEqual([], Rows),
    Rows.

hex(<<"-">>) -> <<>>;
hex(Text) -> binary:decode_hex(Text).

sha3_nist_vectors_test() ->
    lists:foreach(fun([Message, Expected]) ->
        ?assertEqual(hex(Expected), lawspec_beam_crypto:sha3_256(hex(Message)))
    end, vectors(<<"sha3-256">>)).

shake_nist_vectors_and_byte_count_test() ->
    lists:foreach(fun([Message, Count, Expected]) ->
        ?assertEqual(hex(Expected), lawspec_beam_crypto:shake256(hex(Message), binary_to_integer(Count)))
    end, vectors(<<"shake256">>)),
    lists:foreach(fun(N) ->
        ?assertEqual(max(0, N), byte_size(lawspec_beam_crypto:shake256(<<"LawSpec">>, N)))
    end, [-1, 0, 1, 31, 32, 33, 4096]).

aes_nist_vectors_authentication_and_lengths_test() ->
    lists:foreach(fun(Row) ->
        [Key, Nonce, Message, Associated, Ciphertext, Tag] = lists:map(fun hex/1, Row),
        Expected = <<Ciphertext/binary, Tag/binary>>,
        ?assertEqual(Expected, lawspec_beam_crypto:aes256_gcm_encrypt(Key, Nonce, Message, Associated)),
        ?assertEqual({ok, Message}, lawspec_beam_crypto:aes256_gcm_decrypt(Key, Nonce, Expected, Associated)),
        <<First, Rest/binary>> = Expected,
        ?assertEqual(error, lawspec_beam_crypto:aes256_gcm_decrypt(Key, Nonce, <<(First bxor 1), Rest/binary>>, Associated)),
        ?assertEqual(error, lawspec_beam_crypto:aes256_gcm_decrypt(Key, Nonce, Expected, <<Associated/binary, 0>>)),
        ?assertEqual(error, lawspec_beam_crypto:aes256_gcm_decrypt(<<>>, Nonce, Expected, Associated)),
        ?assertEqual(error, lawspec_beam_crypto:aes256_gcm_decrypt(Key, <<>>, Expected, Associated)),
        ?assertEqual(error, lawspec_beam_crypto:aes256_gcm_decrypt(Key, Nonce, <<0:120>>, Associated))
    end, vectors(<<"aes-256-gcm">>)).

seal_uses_nonce_ciphertext_tag_and_rejects_tampering_test() ->
    Key = crypto:strong_rand_bytes(32),
    Message = <<0, 255, 128>>,
    Associated = <<"channel">>,
    Sealed = lawspec_beam_crypto:seal(Key, Message, Associated),
    ?assertEqual(12 + byte_size(Message) + 16, byte_size(Sealed)),
    ?assertEqual({ok, Message}, lawspec_beam_crypto:unseal(Key, Sealed, Associated)),
    ?assertNotEqual(Sealed, lawspec_beam_crypto:seal(Key, Message, Associated)),
    <<First, Rest/binary>> = Sealed,
    ?assertEqual(error, lawspec_beam_crypto:unseal(Key, <<(First bxor 1), Rest/binary>>, Associated)),
    ?assertEqual(error, lawspec_beam_crypto:unseal(crypto:strong_rand_bytes(32), Sealed, Associated)),
    lists:foreach(fun(Length) ->
        ?assertEqual(error, lawspec_beam_crypto:unseal(Key, binary:copy(<<0>>, Length), Associated))
    end, lists:seq(0, 27)).

key_derivation_is_shared_secret_followed_by_context_test() ->
    Secret = <<0, 255, 1>>,
    Context = <<128, 7>>,
    ?assertEqual(crypto:hash_xof(shake256, <<Secret/binary, Context/binary>>, 256),
        lawspec_beam_crypto:derive_aead_key(Secret, Context)).

logical_abilities_keep_the_same_data_contract_test() ->
    Hash = lawspec_beam_crypto:handler(<<"lawspec.crypto::ability::Hash">>),
    Digest = invoke(Hash, <<"sha3">>, [<<"LawSpec">>]),
    ?assertMatch({ls_data, <<"lawspec.crypto::type::Digest::Digest">>, [<<_:32/binary>>]}, Digest),
    Aead = lawspec_beam_crypto:handler(<<"lawspec.crypto::ability::Aead">>),
    Key = invoke(Aead, <<"aeadKey">>, []),
    ?assertMatch({ls_data, <<"lawspec.crypto::type::AeadKey::AeadKey">>, [<<_:32/binary>>]}, Key),
    Sealed = invoke(Aead, <<"seal">>, [Key, <<"message">>, <<"associated">>]),
    ?assertEqual({ls_data, <<"Maybe::Just">>, [<<"message">>]}, invoke(Aead, <<"unseal">>, [Key, Sealed, <<"associated">>])),
    ?assertEqual({ls_data, <<"Maybe::Nothing">>, []}, invoke(Aead, <<"unseal">>, [Key, Sealed, <<"changed">>])).

invoke(Handler, Operation, Args) -> lawspec_beam_effects:invoke(Handler, #{}, Operation, Args).

digest(Bytes) -> binary:encode_hex(lawspec_beam_crypto:sha3_256(Bytes), lowercase).
flip(<<First, Rest/binary>>) -> <<(First bxor 1), Rest/binary>>.

mlkem_key_generation_vectors_and_portable_seed_test() ->
    lists:foreach(fun([D, Z, PublicDigest, PrivateDigest]) ->
        Seed = hex(<<D/binary, Z/binary>>),
        {Public, Private} = lawspec_beam_crypto_native:expand(mlkem768, Seed),
        ?assertEqual(PublicDigest, digest(Public)),
        ?assertEqual(PrivateDigest, digest(Private)),
        ?assertEqual({Public, Seed}, lawspec_beam_crypto:mlkem_keypair(Seed))
    end, vectors(<<"mlkem768-keygen">>)).

mlkem_encapsulation_vectors_test() ->
    lists:foreach(fun(Row) ->
        [Public, Message, Ciphertext, Shared] = lists:map(fun hex/1, Row),
        ?assertEqual({Ciphertext, Shared}, lawspec_beam_crypto_native:encapsulate_test(Public, Message))
    end, vectors(<<"mlkem768-encaps">>)).

mlkem_decapsulation_vectors_and_implicit_rejection_test() ->
    lists:foreach(fun(Row) ->
        [Private, Ciphertext, Shared] = lists:map(fun hex/1, Row),
        ?assertEqual(Shared, lawspec_beam_crypto:mlkem_decapsulate_expanded(Private, Ciphertext))
    end, vectors(<<"mlkem768-decaps">>)),
    lists:foreach(fun(Row) ->
        [Seed, Ciphertext, Shared] = lists:map(fun hex/1, Row),
        ?assertEqual(Shared, lawspec_beam_crypto:mlkem_decapsulate(Seed, Ciphertext))
    end, vectors(<<"mlkem768-decaps-seed">>)).

mlkem_otp_round_trip_test() ->
    {Public, Seed} = lawspec_beam_crypto:mlkem_keypair(crypto:strong_rand_bytes(64)),
    {Ciphertext, Shared} = lawspec_beam_crypto:mlkem_encapsulate(Public),
    ?assertEqual(1088, byte_size(Ciphertext)),
    ?assertEqual(32, byte_size(Shared)),
    ?assertEqual(Shared, lawspec_beam_crypto:mlkem_decapsulate(Seed, Ciphertext)),
    Rejected = lawspec_beam_crypto:mlkem_decapsulate(Seed, flip(Ciphertext)),
    ?assertEqual(32, byte_size(Rejected)),
    ?assertNotEqual(Shared, Rejected),
    ?assertEqual(Rejected, lawspec_beam_crypto:mlkem_decapsulate(Seed, flip(Ciphertext))),
    ?assertNotEqual(Shared, lawspec_beam_crypto:mlkem_decapsulate(crypto:strong_rand_bytes(64), Ciphertext)).

mldsa_key_generation_vectors_test() ->
    lists:foreach(fun([Seed, PublicDigest, PrivateDigest]) ->
        {Public, Private} = lawspec_beam_crypto_native:expand(mldsa65, hex(Seed)),
        ?assertEqual(PublicDigest, digest(Public)),
        ?assertEqual(PrivateDigest, digest(Private)),
        ?assertEqual(Public, lawspec_beam_crypto:mldsa_public(hex(Seed)))
    end, vectors(<<"mldsa65-keygen">>)).

mldsa_verification_vectors_including_context_test() ->
    lists:foreach(fun([Public, Message, Context, Signature, Passed]) ->
        ?assertEqual(Passed =:= <<"true">>, lawspec_beam_crypto:mldsa_verify(hex(Public), hex(Message), hex(Signature), hex(Context)))
    end, vectors(<<"mldsa65-verify">>)).

mldsa_deterministic_signatures_match_byte_for_byte_test() ->
    lists:foreach(fun(Row) ->
        [Seed, Message, Signature] = lists:map(fun hex/1, Row),
        ?assertEqual(Signature, lawspec_beam_crypto:mldsa_sign(Seed, Message, <<>>, true)),
        Public = lawspec_beam_crypto:mldsa_public(Seed),
        ?assert(lawspec_beam_crypto:mldsa_verify(Public, Message, Signature)),
        ?assertNot(lawspec_beam_crypto:mldsa_verify(Public, flip(Message), Signature))
    end, vectors(<<"mldsa65-sign-seed">>)).

mldsa_hedged_signatures_and_context_test() ->
    Seed = crypto:strong_rand_bytes(32),
    Public = lawspec_beam_crypto:mldsa_public(Seed),
    Message = <<0, 255, 128>>,
    Signature = lawspec_beam_crypto:mldsa_sign(Seed, Message),
    ?assertEqual(3309, byte_size(Signature)),
    ?assert(lawspec_beam_crypto:mldsa_verify(Public, Message, Signature)),
    ?assertNotEqual(Signature, lawspec_beam_crypto:mldsa_sign(Seed, Message)),
    ContextSignature = lawspec_beam_crypto:mldsa_sign(Seed, Message, <<"channel">>, false),
    ?assert(lawspec_beam_crypto:mldsa_verify(Public, Message, ContextSignature, <<"channel">>)),
    ?assertNot(lawspec_beam_crypto:mldsa_verify(Public, Message, ContextSignature)),
    ?assertNot(lawspec_beam_crypto:mldsa_verify(Public, Message, ContextSignature, <<"wrong">>)),
    ?assertNot(lawspec_beam_crypto:mldsa_verify(<<>>, Message, Signature)),
    ?assertNot(lawspec_beam_crypto:mldsa_verify(Public, Message, <<>>)),
    ?assertNot(lawspec_beam_crypto:mldsa_verify(Public, Message, Signature, binary:copy(<<0>>, 256))).

slh_key_generation_vectors_test() ->
    lists:foreach(fun([S, P, X, PublicHex, PrivateDigest]) ->
        {Public, Private} = lawspec_beam_crypto:slh_keypair(hex(<<S/binary, P/binary, X/binary>>)),
        ?assertEqual(hex(PublicHex), Public),
        ?assertEqual(PrivateDigest, digest(Private))
    end, vectors(<<"slhdsa128f-keygen">>)).

slh_verification_vectors_including_context_test() ->
    lists:foreach(fun([Public, Message, Context, Signature, Passed]) ->
        ?assertEqual(Passed =:= <<"true">>, lawspec_beam_crypto:slh_verify(hex(Public), hex(Message), hex(Signature), hex(Context))),
        ?assertNot(lawspec_beam_crypto:slh_verify(hex(Public), flip(hex(Message)), hex(Signature), hex(Context)))
    end, vectors(<<"slhdsa128f-verify">>)).

slh_otp_round_trip_and_context_test() ->
    {Public, Private} = lawspec_beam_crypto:slh_keypair(),
    ?assertEqual(32, byte_size(Public)),
    ?assertEqual(64, byte_size(Private)),
    Message = <<"LawSpec">>,
    Signature = lawspec_beam_crypto:slh_sign(Private, Message),
    ?assertEqual(17088, byte_size(Signature)),
    ?assert(lawspec_beam_crypto:slh_verify(Public, Message, Signature)),
    ?assertNot(lawspec_beam_crypto:slh_verify(Public, flip(Message), Signature)),
    ?assertNotEqual(Signature, lawspec_beam_crypto:slh_sign(Private, Message)),
    ContextSignature = lawspec_beam_crypto:slh_sign(Private, Message, <<"channel">>),
    ?assert(lawspec_beam_crypto:slh_verify(Public, Message, ContextSignature, <<"channel">>)),
    ?assertNot(lawspec_beam_crypto:slh_verify(Public, Message, ContextSignature)),
    ?assertNot(lawspec_beam_crypto:slh_verify(<<>>, Message, Signature)),
    ?assertNot(lawspec_beam_crypto:slh_verify(Public, Message, <<>>)).

native_bridge_rejects_malformed_inputs_test() ->
    lists:foreach(fun({Algorithm, Size}) ->
        ?assertError(badarg, lawspec_beam_crypto_native:expand(Algorithm, <<>>)),
        ?assertError(badarg, lawspec_beam_crypto_native:expand(Algorithm, binary:copy(<<0>>, Size + 1)))
    end, [{mlkem768, 64}, {mldsa65, 32}, {slh_dsa_shake_128f, 48}]),
    ?assertError(badarg, lawspec_beam_crypto_native:expand(unsupported, <<>>)),
    ?assertError(badarg, lawspec_beam_crypto_native:expand(42, <<>>)),
    ?assertError(badarg, lawspec_beam_crypto_native:encapsulate_test(<<>>, <<>>)),
    ?assertError(badarg, lawspec_beam_crypto_native:sign_context(mlkem768, <<>>, <<>>, <<>>, false)),
    ?assertError(badarg, lawspec_beam_crypto_native:sign_context(mldsa65, <<0:256>>, <<>>, <<>>, 1)),
    ?assertError(badarg, lawspec_beam_crypto_native:sign_context(mldsa65, <<0:256>>, <<>>, binary:copy(<<0>>, 256), false)),
    ?assertNot(lawspec_beam_crypto_native:verify_context(mldsa65, <<>>, <<>>, <<>>, <<>>)).

native_operations_are_independent_across_processes_test() ->
    Workers = [spawn_monitor(fun() ->
        Seed = <<N:256>>,
        Public = lawspec_beam_crypto:mldsa_public(Seed),
        Signature = lawspec_beam_crypto:mldsa_sign(Seed, <<N>>, <<"parallel">>, true),
        true = lawspec_beam_crypto:mldsa_verify(Public, <<N>>, Signature, <<"parallel">>),
        false = lawspec_beam_crypto:mldsa_verify(Public, <<(N + 1)>>, Signature, <<"parallel">>)
    end) || N <- lists:seq(1, 32)],
    lists:foreach(fun({Pid, Monitor}) ->
        receive {'DOWN', Monitor, process, Pid, Reason} -> ?assertEqual(normal, Reason)
        after 4000 -> error(crypto_worker_timeout) end
    end, Workers).
