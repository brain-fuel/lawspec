%% @doc Scalar bridges must preserve the Core domain and IEEE edge cases.
%% ref:DEC-portable-exact-arithmetic ref:ieee-754
-module(lawspec_beam_scalar_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Cases = json:decode(Bytes),
    lists:foreach(fun vector/1, Cases),
    io:format("~B BEAM scalar cases match Core.~n", [length(Cases)]).

vector(#{<<"kind">> := Kind, <<"op">> := Op, <<"args">> := Args,
        <<"types">> := Types, <<"machineBits">> := Bits} = Case) ->
    Context = make_ref(),
    Values = [lawspec_beam_scalar:literal(V, Context) || V <- Args],
    Actual = try
        {value, case {Kind, Values} of
            {<<"literal">>, [A]} -> A;
            {<<"binary">>, [A, B]} ->
                [TA, TB] = Types, lawspec_beam_scalar:binary(Op, A, B, TA, TB);
            {<<"convert">>, [A]} -> lawspec_beam_scalar:convert(A, Op, Bits);
            {<<"helper">>, _} -> lawspec_beam_scalar:helper(Op, Values, Types, Bits)
        end}
    catch error:Reason -> {error, Reason} end,
    case {maps:find(<<"expected">>, Case), Actual} of
        {{ok, ExpectedWire}, {value, Got}} ->
            Expected = lawspec_beam_scalar:literal(ExpectedWire, Context),
            Matches = case Kind of
                <<"literal">> -> Expected =:= Got;
                _ -> same(Expected, Got)
            end,
            case Matches of true -> ok; false -> erlang:error({scalar_mismatch, Case, Got}) end;
        {error, {error, _}} -> ok;
        _ -> erlang:error({scalar_mismatch, Case, Actual})
    end.

same({ls_float, W, _} = A, {ls_float, W, _} = B) ->
    A =:= B orelse (lawspec_beam_scalar:float_class(A) =:= nan andalso
                   lawspec_beam_scalar:float_class(B) =:= nan);
same({ls_complex, W, AR, AI}, {ls_complex, W, BR, BI}) -> same(AR, BR) andalso same(AI, BI);
same(A, B) -> lawspec_beam_scalar:equal(A, B).

machine_width_test() ->
    ?assertEqual(4294967295, lawspec_beam_scalar:validate(4294967295, <<"UIntSize">>, 32)),
    ?assertError({lawspec, {integer_out_of_range, <<"UIntSize">>}},
        lawspec_beam_scalar:validate(4294967296, <<"UIntSize">>, 32)),
    ?assertEqual(4294967296, lawspec_beam_scalar:validate(4294967296, <<"UIntSize">>, 64)).

ieee_native_bridge_test() ->
    NegZero = lawspec_beam_scalar:float_bits(64, 16#8000000000000000),
    Native = lawspec_beam_scalar:float_to_native(NegZero),
    ?assertEqual(NegZero, lawspec_beam_scalar:float_from_native(64, Native)),
    ?assertError({lawspec, non_finite_native_float},
        lawspec_beam_scalar:float_to_native(lawspec_beam_scalar:float_bits(32, 16#7f800000))).

subnormal_rounding_test() ->
    ?assertEqual({ls_float, 32, 0}, lawspec_beam_scalar:float_from_ratio(32, 1, 1 bsl 150, 0)),
    ?assertEqual({ls_float, 32, 2}, lawspec_beam_scalar:float_from_ratio(32, 3, 1 bsl 150, 0)),
    ?assertEqual({ls_float, 64, 2}, lawspec_beam_scalar:float_from_ratio(64, 3, 1 bsl 1075, 0)).

recursive_nan_equality_test() ->
    NaN = lawspec_beam_scalar:float_bits(64, 16#7ff8000000000001),
    ?assertNot(lawspec_beam_scalar:equal([NaN], [NaN])),
    ?assertNot(lawspec_beam_scalar:equal({ls_data, <<"Box">>, [NaN]}, {ls_data, <<"Box">>, [NaN]})).

symbol_scope_test() ->
    Symbol = #{<<"type">> => <<"Symbol">>, <<"id">> => <<"a">>, <<"description">> => <<"same">>},
    Context = make_ref(),
    A = lawspec_beam_scalar:literal(Symbol, Context),
    ?assert(lawspec_beam_scalar:equal(A, lawspec_beam_scalar:literal(Symbol, Context))),
    ?assertNot(lawspec_beam_scalar:equal(A, lawspec_beam_scalar:literal(Symbol, make_ref()))),
    ?assertNot(lawspec_beam_scalar:equal(lawspec_beam_scalar:new_symbol(<<"same">>),
        lawspec_beam_scalar:new_symbol(<<"same">>))).

nested_presence_wire_test() ->
    V = {ls_presence, <<"Optional">>, {some, {ls_presence, <<"Nullable">>, {some, <<255>>}}}},
    W = lawspec_beam_scalar:wire(V, <<"Optional (Nullable Bytes)">>),
    ?assertEqual(V, lawspec_beam_scalar:literal(W)),
    ?assertEqual(#{<<"type">> => <<"Optional">>, <<"value">> =>
        #{<<"type">> => <<"Nullable">>, <<"value">> =>
            #{<<"type">> => <<"Bytes">>, <<"units">> => [255]}}}, W).

presence_conversion_test() ->
    ?assertEqual({ls_presence, <<"Optional">>, {some, {ls_ratio, 42, 1}}},
        lawspec_beam_scalar:convert({ls_presence, <<"Optional">>, {some, 42}},
            <<"Optional Rational">>, 64)).

unicode_domain_test() ->
    ?assertError({lawspec, {invalid_character, <<"Char">>}},
        lawspec_beam_scalar:validate(16#d800, <<"Char">>, 64)),
    ?assertEqual(16#d800, lawspec_beam_scalar:validate(16#d800, <<"CodePoint">>, 64)),
    ?assertError({lawspec, invalid_unicode}, lawspec_beam_scalar:validate(<<255>>, <<"Text">>, 64)),
    ?assertEqual(2, lawspec_beam_scalar:helper(<<"length">>, [<<955/utf8, 128512/utf8>>], [<<"Text">>], 64)).

type_key_test() ->
    A = {<<"List">>, [{<<"Int8">>, []}]},
    B = {<<"Optional">>, [{<<"Maybe">>, [{<<"Text">>, []}]}]},
    ?assertEqual({<<"Either">>, [A, B]},
        lawspec_beam_scalar:type(<<"Either (List Int8) (Optional (Maybe Text))">>)).

portable_order_test() ->
    ?assertEqual(-1, lawspec_beam_scalar:compare({ls_data, <<"Maybe::Nothing">>, []},
        {ls_data, <<"Maybe::Just">>, [1]})),
    ?assertEqual(0, lawspec_beam_scalar:compare({ls_decimal, 15, -1}, {ls_ratio, 3, 2})).
