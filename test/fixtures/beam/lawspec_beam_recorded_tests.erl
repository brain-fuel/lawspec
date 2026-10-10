%% @doc Recorded text must cover all scalar families without changing the
%% existing model-domain recordings. ref:REQ-law-primitives
-module(lawspec_beam_recorded_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Rows = json:decode(Bytes),
    lists:foreach(fun(#{<<"name">> := Name, <<"scalar">> := Scalar, <<"text">> := Expected} = Row) ->
        Actual = text(lawspec_beam_scalar:literal(Scalar), maps:get(<<"type">>, Row, maps:get(<<"type">>, Scalar))),
        ?assertEqual({Name, Expected}, {Name, Actual})
    end, Rows),
    io:format("~B BEAM recorded scalar vectors passed~n", [length(Rows)]).

text(V, T) -> lawspec_beam_recorded:text(V, T).
type(T) -> {T, []}.

basic_recordings_stay_compatible_test() ->
    lists:foreach(fun({V, T}) ->
        ?assertEqual(lawspec_beam_values:render(V), text(V, T))
    end, [{42, <<"Integer">>}, {true, <<"Bool">>}, {false, <<"Bool">>},
        {ls_unit, <<"Unit">>}, {<<"雪\"\\\n"/utf8>>, <<"Text">>},
        {[1, -2], <<"List Integer">>},
        {{ls_data, <<"Maybe::Just">>, [<<"post">>]}, <<"Maybe Text">>},
        {{ls_data, <<"Either::Left">>, [ls_unit]}, <<"Either (Unit) (Text)">>}]).

raw_sequences_and_characters_test() ->
    ?assertEqual(<<"bytes([0, 34, 92, 255])">>, text(<<0, 34, 92, 255>>, <<"Bytes">>)),
    ?assertEqual(<<"codePoints([65, 55296, 1114111])">>,
        text({ls_raw, <<"CodePointText">>, [65, 55296, 1114111]}, <<"CodePointText">>)),
    ?assertEqual(<<"utf16([65, 55296])">>, text({ls_raw, <<"Utf16Text">>, [65, 55296]}, <<"Utf16Text">>)),
    ?assertEqual(<<"\"雪\""/utf8>>, text(38634, <<"Char">>)),
    ?assertEqual(<<"55296">>, text(55296, <<"CodePoint">>)),
    ?assertEqual(<<"65535">>, text(65535, <<"CodeUnit16">>)).

exact_numbers_test() ->
    ?assertEqual(<<"125e-2">>, text({ls_decimal, 125, -2}, <<"Decimal">>)),
    ?assertEqual(<<"125e-2">>, text({ls_decimal, 12500, -4}, <<"Decimal">>)),
    ?assertEqual(<<"-125e-2">>, text({ls_decimal, -12500, -4}, <<"Decimal">>)),
    ?assertEqual(<<"0e0">>, text({ls_decimal, 0, 100000000000000000000}, <<"Decimal">>)),
    ?assertEqual(<<"1e100000000000000000000">>,
        text({ls_decimal, 1, 100000000000000000000}, <<"Decimal">>)),
    ?assertEqual(<<"rational(-2, 3)">>, text({ls_ratio, 4, -6}, <<"Rational">>)),
    ?assertEqual(integer_to_binary(1 bsl 200), text(1 bsl 200, <<"BigUInt">>)).

ieee_recordings_test() ->
    lists:foreach(fun({W, T, Bits, Expected}) ->
        ?assertEqual(Expected, text({ls_float, W, Bits}, T))
    end, [{32, <<"Float32">>, 16#3fa00000, <<"float32Bits(\"3fa00000\")">>},
        {64, <<"Float64">>, 16#8000000000000000, <<"float64Bits(\"8000000000000000\")">>},
        {32, <<"Float32">>, 0, <<"float32Bits(\"00000000\")">>},
        {32, <<"Float32">>, 1, <<"float32Bits(\"00000001\")">>},
        {64, <<"Float64">>, 16#7ff0000000000000, <<"float64Bits(\"7ff0000000000000\")">>},
        {32, <<"Float32">>, 16#ffc00001, <<"float32NaN">>},
        {64, <<"Float64">>, 16#7ff0000000000001, <<"float64NaN">>}]),
    ?assertEqual(<<"Complex64(float32Bits(\"3f800000\"), float32Bits(\"40000000\"))">>,
        text({ls_complex, 32, {ls_float, 32, 16#3f800000}, {ls_float, 32, 16#40000000}}, <<"Complex64">>)).

presence_records_nested_values_test() ->
    ?assertEqual(<<"null">>, text(ls_null, <<"Null">>)),
    ?assertEqual(<<"undefined">>, text(ls_undefined, <<"Undefined">>)),
    ?assertEqual(<<"null">>, text({ls_presence, <<"Nullable">>, none}, <<"Nullable Integer">>)),
    ?assertEqual(<<"undefined">>, text({ls_presence, <<"Optional">>, none}, <<"Optional Integer">>)),
    V = {ls_presence, <<"Optional">>, {some, {ls_presence, <<"Nullable">>, {some, [<<0, 255>>]}}}},
    ?assertEqual(<<"optional(nullable([bytes([0, 255])]))">>,
        text(V, <<"Optional (Nullable (List Bytes))">>)).

identities_are_local_to_one_recording_test() ->
    A = {ls_symbol, make_ref(), <<"same">>}, B = {ls_symbol, make_ref(), <<"same">>},
    ?assertEqual(<<"[symbol(1, \"same\"), symbol(2, \"same\"), symbol(1, \"same\")]">>,
        text([A, B, A], <<"List Symbol">>)),
    ?assertEqual(<<"symbol(1, \"same\")">>, text(B, <<"Symbol">>)),
    H = {ls_handle, <<"example::Worker">>, make_ref()},
    Other = {ls_handle, <<"example::Worker">>, make_ref()},
    ?assertEqual(<<"[Worker#1, Worker#2, Worker#1]">>, text([H, Other, H], <<"List example::Worker">>)).

schema_preserves_basic_records_and_types_nested_fields_test() ->
    Pair = #{name => <<"Pair">>, parameters => 2, constructors => [
        #{tag => <<"example::Pair">>, native_tag => pair,
          fields => [{<<"a">>, {parameter, 0}}, {<<"b">>, {parameter, 1}}],
          predicates => [fun(_, _, _) -> error(predicate_must_not_run_when_recording) end]}]},
    S = schema([Pair]),
    Value = {ls_data, <<"example::Pair">>, [7, <<"post">>]},
    ?assertEqual(lawspec_beam_values:render(Value),
        lawspec_beam_recorded:text(Value, {<<"Pair">>, [type(<<"Integer">>), type(<<"Text">>)]}, S)),
    Typed = {ls_data, <<"example::Pair">>, [<<0, 255>>, 38634]},
    ?assertEqual(<<"Pair(bytes([0, 255]), \"雪\")"/utf8>>,
        lawspec_beam_recorded:text(Typed, {<<"Pair">>, [type(<<"Bytes">>), type(<<"Char">>)]}, S)).

existential_witnesses_resolve_recording_types_test() ->
    Box = #{name => <<"Box">>, parameters => 0, constructors => [
        #{tag => <<"Box::Box">>, native_tag => box, existentials => 1, witnesses => [0],
          fields => [{<<"value">>, {parameter, 0}}, {<<"witness">>, type(<<"Text">>)}]}]},
    S = schema([Box]),
    ?assertEqual(<<"Box(bytes([255]), \"Bytes\")">>, lawspec_beam_recorded:text(
        {ls_data, <<"Box::Box">>, [<<255>>, <<"Bytes">>]}, <<"Box">>, S)).

schema(Ds) -> lawspec_beam_schema:new(Ds,
    [<<"Integer">>, <<"Bool">>, <<"Text">>, <<"Bytes">>, <<"Char">>, <<"Unit">>], 64).
