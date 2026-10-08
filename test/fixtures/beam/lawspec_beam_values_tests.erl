%% @doc Portable descriptors preserve existing replay and network semantics.
%% ref:DEC-portable-seeded-generation ref:DEC-distribution-canonical-wire
-module(lawspec_beam_values_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Cases = json:decode(Bytes),
    lists:foreach(fun vector/1, Cases),
    io:format("~B BEAM descriptor sequences match the portable runtime.~n", [length(Cases)]).
vector(#{<<"descriptor">> := Text, <<"seed">> := Seed, <<"size">> := Size,
        <<"expected">> := Expected, <<"state">> := End, <<"shrunk">> := Shrunk}) ->
    {Table, D} = lawspec_beam_values:from_text(Text),
    {Values, Last} = lists:mapfoldl(fun(_, S) -> lawspec_beam_values:generate(D, Table, S, Size) end,
        lawspec_beam_random:seed(Seed), Expected),
    ?assertEqual(End, Last),
    lists:foreach(fun({V, #{<<"text">> := Rendered, <<"wire">> := Hex}}) ->
        ?assertEqual(Rendered, lawspec_beam_values:render(V)),
        Binary = binary:decode_hex(string:uppercase(Hex)),
        ?assertEqual(Binary, lawspec_beam_values:encode(D, V, Table)),
        ?assertEqual(V, lawspec_beam_values:decode(D, Binary, Table))
    end, lists:zip(Values, Expected)),
    [First | _] = Values,
    ?assertEqual(Shrunk, [lawspec_beam_values:render(V) || V <- lawspec_beam_values:shrink(D, First, Table)]).

splitmix64_known_sequence_test() ->
    {N1, S1} = lawspec_beam_random:next(0),
    {N2, S2} = lawspec_beam_random:next(S1),
    ?assertEqual(16#e220a8397b1dcdaf, N1),
    ?assertEqual(16#6e789e6aa1b965f4, N2),
    ?assertEqual({0, S2}, lawspec_beam_random:below(0, S2)),
    ?assertEqual(16#ffffffffffffffff, lawspec_beam_random:seed(-1)).

unicode_wire_test() ->
    D = [<<"text">>], V = <<955/utf8, 128512/utf8>>,
    B = <<6, V/binary>>,
    ?assertEqual(B, lawspec_beam_values:encode(D, V, #{})),
    ?assertEqual(V, lawspec_beam_values:decode(D, B, #{})),
    ?assertEqual([<<>>, <<955/utf8>>, <<128512/utf8>>], lawspec_beam_values:shrink(D, V, #{})).

descriptor_parser_test() ->
    ?assertEqual([[<<"data">>, <<"X">>, [<<"ctor">>, {quoted, <<"quoted \"name\"">>},
        [<<"int">>, <<"Integer">>, -5, none]]]],
        lawspec_beam_values:read_descriptor(<<"(data X (ctor \"quoted \\\"name\\\"\" (int Integer -5 _)))">>)),
    ?assertError({lawspec, unclosed_descriptor}, lawspec_beam_values:read_descriptor(<<"(list">>)),
    ?assertError({lawspec, trailing_descriptor_input}, lawspec_beam_values:read_descriptor(<<"() )">>)).

invalid_wire_test() ->
    ?assertError({lawspec, wire_integer_out_of_range},
        lawspec_beam_values:decode([<<"int">>, <<"Int8">>, -128, 127], <<128, 2>>, #{})),
    ?assertError({lawspec, wire_integer_out_of_range},
        lawspec_beam_values:encode([<<"int">>, <<"Int8">>, -128, 127], true, #{})),
    ?assertError({lawspec, truncated_wire_value},
        lawspec_beam_values:decode([<<"text">>], <<3, "ab">>, #{})),
    ?assertError({lawspec, trailing_wire_bytes},
        lawspec_beam_values:decode([<<"bool">>], <<1, 0>>, #{})),
    ?assertError({lawspec, wire_invalid_utf8},
        lawspec_beam_values:decode([<<"text">>], <<1, 255>>, #{})),
    ?assertError({lawspec, {invalid_wire_value, [<<"bool">>]}},
        lawspec_beam_values:decode([<<"bool">>], <<2>>, #{})).
