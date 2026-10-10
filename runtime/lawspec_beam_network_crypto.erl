%% @doc The portable LS version 1 records. Cryptographic primitives and
%% compact seed expansion come from OTP and the existing OpenSSL bridge.
%% ref:DEC-distribution-canonical-wire
-module(lawspec_beam_network_crypto).
-export([identity/1, fingerprint/1, public/1, sign/2, verify/3,
    hello/4, welcome/5, key/3, record/3, read/1, seal/4, seal/5, open/4]).
-export_type([identity/0]).
-opaque identity() :: {lawspec_node_identity, binary(), binary()}.

identity(Seed) when is_binary(Seed), byte_size(Seed) =:= 32 ->
    {lawspec_node_identity, Seed, lawspec_beam_crypto:mldsa_public(Seed)};
identity(_) -> error({lawspec, invalid_node_identity}).
public({lawspec_node_identity, _, Public}) -> Public.
fingerprint(Identity) -> hex(lawspec_beam_crypto:sha3_256(public(Identity))).
hex(Bytes) -> string:lowercase(binary:encode_hex(Bytes)).
sign({lawspec_node_identity, Seed, _}, Bytes) -> lawspec_beam_crypto:mldsa_sign(Seed, Bytes).
verify(Public, Bytes, Signature) -> lawspec_beam_crypto:mldsa_verify(Public, Bytes, Signature).
hello(Session, Address, Public, Kem) -> fields([Session, Address, Public, Kem]).
welcome(Session, Address, Public, Ciphertext, Hello) ->
    fields([Session, Address, Public, Ciphertext, lawspec_beam_crypto:sha3_256(Hello)]).
key(Shared, Hello, Welcome) -> lawspec_beam_crypto:shake256(
    [Shared, <<"lawspec-session-v1">>, lawspec_beam_crypto:sha3_256(Hello), lawspec_beam_crypto:sha3_256(Welcome)], 32).
record(Kind, Body, Signature) -> <<"LS", 1, Kind, Body/binary, (fields([Signature]))/binary>>.
fields(Values) -> lawspec_beam_wire:fields(lists:duplicate(length(Values), [<<"bytes">>]), Values, #{}).
read_fields(Count, Bytes) -> lawspec_beam_wire:read_fields(lists:duplicate(Count, [<<"bytes">>]), Bytes, #{}).

read(<<"LS", 1, Kind, Bytes/binary>>) when Kind =:= 1; Kind =:= 2 ->
    Count = case Kind of 1 -> 4; 2 -> 5 end,
    {Values, Rest} = read_fields(Count, Bytes),
    {[Signature], <<>>} = read_fields(1, Rest),
    Body = binary:part(Bytes, 0, byte_size(Bytes) - byte_size(Rest)),
    {Kind, Values, Body, Signature};
read(<<"LS", 1, 3, Bytes/binary>>) ->
    {[Session], <<Direction, Rest/binary>>} = read_fields(1, Bytes),
    {[Sealed], <<>>} = read_fields(1, Rest),
    {3, Session, Direction, Sealed};
read(_) -> error(invalid_secure_record).
seal(Key, Session, Direction, Frame) -> seal(Key, Session, Direction, Frame, crypto:strong_rand_bytes(12)).
seal(Key, Session, Direction, Frame, Nonce) ->
    Associated = <<"lawspec-frame-v1", Session/binary, Direction>>,
    Sealed = <<Nonce/binary, (lawspec_beam_crypto:aes256_gcm_encrypt(Key, Nonce, Frame, Associated))/binary>>,
    <<"LS", 1, 3, (fields([Session]))/binary, Direction, (fields([Sealed]))/binary>>.
open(Key, Session, Direction, Sealed) ->
    lawspec_beam_crypto:unseal(Key, Sealed, <<"lawspec-frame-v1", Session/binary, Direction>>).
