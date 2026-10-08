%% @doc Frame bytes interoperate across targets and contain no BEAM terms.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_wire_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

canonical_frame_and_sequence_bytes_test() ->
    F = lawspec_beam_wire:frame(<<"mail">>, <<"m">>, <<"mem://a">>, 7, <<0, 255>>),
    ?assertEqual(<<4,"mail",1,"m",7,"mem://a",14,2,0,255>>, F),
    ?assertEqual({ok, #{kind => <<"mail">>, to => <<"m">>, source => <<"mem://a">>, id => 7, payload => <<0, 255>>}},
        lawspec_beam_wire:read_frame(F)),
    ?assertEqual(<<1>>, lawspec_beam_wire:sequence(-1)),
    ?assertEqual(-1, lawspec_beam_wire:read_sequence(<<1>>)),
    ?assertEqual(<<128, 1>>, lawspec_beam_wire:sequence(64)).

channel_body_is_raw_after_its_typed_prefix_test() ->
    F = lawspec_beam_wire:channel(-1, <<"mem://b/end-1">>, <<"hello">>),
    ?assertEqual(<<1, 13, "mem://b/end-1hello">>, F),
    ?assertEqual({-1, <<"mem://b/end-1">>, <<"hello">>}, lawspec_beam_wire:read_channel(F)),
    ?assertEqual({0, <<"x">>, <<0, 255>>}, lawspec_beam_wire:read_channel(lawspec_beam_wire:channel(0, <<"x">>, <<0, 255>>))).

frame_lengths_utf8_bounds_and_trailing_bytes_test() ->
    F = lawspec_beam_wire:frame(<<"reply">>, <<>>, <<"mem://a">>, 0, <<>>),
    ?assertEqual({error, invalid_frame}, lawspec_beam_wire:read_frame(<<F/binary, 0>>)),
    lists:foreach(fun(N) -> ?assertEqual({error, invalid_frame}, lawspec_beam_wire:read_frame(binary:part(F, 0, N))) end,
        lists:seq(0, byte_size(F) - 1)),
    ?assertEqual({error, invalid_frame}, lawspec_beam_wire:read_frame(<<1, 255, 0, 0, 0, 0>>)),
    ?assertEqual({error, invalid_frame}, lawspec_beam_wire:read_frame(<<0, 0, 0, 1, 0>>)),
    Huge = iolist_to_binary(lawspec_beam_values:varint(1 bsl 65)),
    ?assertEqual({error, invalid_frame}, lawspec_beam_wire:read_frame(<<0, 0, 0, Huge/binary, 0>>)),
    ?assertError({lawspec, wire_integer_out_of_range}, lawspec_beam_wire:frame(<<>>, <<>>, <<>>, -1, <<>>)),
    ?assertError({lawspec, wire_integer_out_of_range}, lawspec_beam_wire:sequence(1 bsl 63)).

address_keeps_node_and_entity_separate_test() ->
    ?assertEqual({<<"mem://a">>, <<"mailbox">>}, lawspec_beam_wire:split_address(<<"mem://a/mailbox">>)),
    ?assertEqual({<<"tcp://[::1]:1234">>, <<"actor">>}, lawspec_beam_wire:split_address(<<"tcp://[::1]:1234/actor">>)),
    ?assertEqual({<<"http://localhost:1234">>, <<>>}, lawspec_beam_wire:split_address(<<"http://localhost:1234/">>)),
    ?assertError({lawspec, {invalid_address, <<"a/b">>}}, lawspec_beam_wire:split_address(<<"a/b">>)),
    ?assertError({lawspec, {invalid_address, <<"mem://a">>}}, lawspec_beam_wire:split_address(<<"mem://a">>)).

field_prefix_decoding_leaves_the_remaining_payload_test() ->
    Ds = [[<<"text">>], [<<"int">>, <<"Int8">>, -128, 127]],
    Prefix = lawspec_beam_wire:fields(Ds, [<<"hello">>, -42], #{}),
    ?assertEqual({[<<"hello">>, -42], <<"rest">>}, lawspec_beam_wire:read_fields(Ds, <<Prefix/binary, "rest">>, #{})).

vectors(Path) ->
    {ok, Data} = file:read_file(Path), Vectors = json:decode(Data),
    lists:foreach(fun(#{<<"kind">> := Kind, <<"to">> := To, <<"source">> := Source,
            <<"id">> := Id, <<"payload">> := Payload, <<"frame">> := Frame}) ->
        Bytes = base64:decode(Frame), Body = base64:decode(Payload),
        ?assertEqual(Bytes, lawspec_beam_wire:frame(Kind, To, Source, Id, Body)),
        ?assertEqual({ok, #{kind => Kind, to => To, source => Source, id => Id, payload => Body}}, lawspec_beam_wire:read_frame(Bytes))
    end, Vectors),
    io:format("~B distribution frames match the portable canonical bytes~n", [length(Vectors)]).
