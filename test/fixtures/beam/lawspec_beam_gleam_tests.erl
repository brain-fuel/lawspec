%% ref:DEC-native-bindings-typed-identity ref:DEC-tests-cite-requirements
-module(lawspec_beam_gleam_tests).
-include_lib("eunit/include/eunit.hrl").

schema() -> lawspec_beam_schema:with_codecs(lawspec_beam_schema:new([],
    [<<"Unit">>, <<"Null">>, <<"Undefined">>, <<"Int8">>], 64), lawspec_beam_gleam:codecs()).

native_builtin_shapes_test() ->
    S = schema(), I = {<<"Int8">>, []},
    Pairs = [
        {{<<"Unit">>, []}, ls_unit, nil},
        {{<<"Null">>, []}, ls_null, null},
        {{<<"Undefined">>, []}, ls_undefined, undefined},
        {{<<"Maybe">>, [I]}, {ls_data, <<"Maybe::Nothing">>, []}, none},
        {{<<"Maybe">>, [I]}, {ls_data, <<"Maybe::Just">>, [127]}, {some, 127}},
        {{<<"Either">>, [I,I]}, {ls_data, <<"Either::Left">>, [-128]}, {error, -128}},
        {{<<"Either">>, [I,I]}, {ls_data, <<"Either::Right">>, [127]}, {ok, 127}}
    ],
    lists:foreach(fun({T, C, Native}) ->
        ?assertEqual(Native, lawspec_beam_schema:to_native(C, T, S)),
        ?assertEqual(C, lawspec_beam_schema:from_native(Native, T, S))
    end, Pairs),
    ?assertError({lawspec, {invalid_gleam_value, unit}}, lawspec_beam_schema:from_native(ok, {<<"Unit">>, []}, S)),
    ?assertError({lawspec, {integer_out_of_range, <<"Int8">>}},
        lawspec_beam_schema:from_native({some, 128}, {<<"Maybe">>, [I]}, S)).

nested_presence_is_not_collapsed_test() ->
    S = schema(), T = {<<"Optional">>, [{<<"Nullable">>, [{<<"Int8">>, []}]}]},
    Values = [absent, {present, null_value}, {present, {non_null, 127}}],
    lists:foreach(fun(V) ->
        C = lawspec_beam_schema:from_native(V, T, S),
        ?assertEqual(V, lawspec_beam_schema:to_native(C, T, S))
    end, Values).

ieee_facade_preserves_bits_test() ->
    Zero = lawspec_beam_gleam:float64_from_bits(1 bsl 63),
    {ok, Native} = lawspec_beam_gleam:float_to_native(Zero),
    ?assertEqual(Zero, lawspec_beam_gleam:float64_from_native(Native)),
    Nan = lawspec_beam_gleam:float32_from_bits(16#7fc00000),
    ?assertMatch({error, _}, lawspec_beam_gleam:float_to_native(Nan)),
    ?assertEqual(none, lawspec_beam_gleam:scalar_compare(Nan, Nan)),
    ?assertEqual({some, 0}, lawspec_beam_gleam:scalar_compare(Zero, Zero)).
