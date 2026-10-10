%% @doc Seeded search checks laws on actual candidates, with exact scores.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(lawspec_beam_search_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

integer_moves_test() ->
    D = [<<"int">>, <<"Int8">>, -10, 10],
    ?assertEqual([4, 2, 6, 1, -3], lawspec_beam_search:moves(D, 3, #{})),
    ?assertEqual([-2, -4, -6, -1, 3], lawspec_beam_search:moves(D, -3, #{})),
    ?assertEqual([], lawspec_beam_search:moves([<<"int">>, <<"Integer">>, 7, 7], 7, #{})),
    ?assertEqual([1, 1000000], lawspec_beam_search:moves([<<"int">>, <<"BigUInt">>, 0, none], 0, #{})).

nested_moves_keep_shapes_test() ->
    D = [<<"int">>, <<"Integer">>, 0, 10],
    Box = [<<"data">>, <<"Box">>, [<<"ctor">>, <<"Box::Box">>, [<<"list">>, [<<"maybe">>, D]]]],
    V = {ls_data, <<"Box::Box">>, [[{ls_data, <<"Maybe::Nothing">>, []}, {ls_data, <<"Maybe::Just">>, [3]}]]},
    Expected = [{ls_data, <<"Box::Box">>, [[{ls_data, <<"Maybe::Nothing">>, []}, {ls_data, <<"Maybe::Just">>, [N]}]]}
        || N <- lawspec_beam_search:moves(D, 3, #{})],
    ?assertEqual(Expected, lawspec_beam_search:moves([<<"ref">>, <<"Box">>], V, #{<<"Box">> => Box})).

exact_scores_test() ->
    Huge = 1 bsl 200,
    ?assert(lawspec_beam_harness:higher(Huge + 1, {score, Huge})),
    ?assertNot(lawspec_beam_harness:higher(Huge, {score, Huge + 1})),
    ?assert(lawspec_beam_harness:higher({ls_ratio, Huge + 1, 3}, {score, {ls_ratio, Huge, 3}})),
    ?assert(lawspec_beam_harness:higher({ls_decimal, Huge + 1, -40}, {score, {ls_decimal, Huge, -40}})),
    ?assertEqual(<<"123e-4">>, lawspec_beam_harness:score_text({ls_decimal, 123, -4})),
    ?assertEqual(<<"2/3">>, lawspec_beam_harness:score_text({ls_ratio, 2, 3})).

ieee_scores_test() ->
    NaN = {ls_float, 64, 16#7ff8000000000000},
    Infinity = {ls_float, 64, 16#7ff0000000000000},
    NegativeInfinity = {ls_float, 64, 16#fff0000000000000},
    One = lawspec_beam_scalar:float_from_native(64, 1.0),
    ?assertNot(lawspec_beam_harness:higher(NaN, none)),
    ?assertNot(lawspec_beam_harness:higher(NaN, {score, One})),
    ?assert(lawspec_beam_harness:higher(One, {score, NegativeInfinity})),
    ?assert(lawspec_beam_harness:higher(Infinity, {score, One})),
    ?assertEqual(<<"Infinity">>, lawspec_beam_harness:score_text(Infinity)),
    ?assertEqual(<<"-Infinity">>, lawspec_beam_harness:score_text(NegativeInfinity)),
    ?assertEqual(<<"1.0">>, lawspec_beam_harness:score_text(One)).

interior_maximum_and_replay_test() -> with_directory(fun(Directory) ->
    Descriptor = <<"(int Int32 0 1000)">>,
    First = trace(<<"peak">>, [Descriptor], fun([N]) -> {score, -(N - 137) * (N - 137)} end),
    Second = trace(<<"peak">>, [Descriptor], fun([N]) -> {score, -(N - 137) * (N - 137)} end),
    ?assertEqual(First, Second),
    ?assert(lists:member([137], First)),
    ?assert(length(First) =< 400),
    [#{<<"search">> := Search}] = reports(Directory),
    ?assertEqual(<<"0">>, maps:get(<<"best">>, Search)),
    ?assertEqual(length(First), maps:get(<<"tried">>, Search))
end).

wide_target_retains_last_bit_test() -> with_directory(fun(Directory) ->
    Lo = 1 bsl 128,
    Descriptor = iolist_to_binary(["(int Integer ", integer_to_binary(Lo), " ", integer_to_binary(Lo + 1000), ")"]),
    Values = trace(<<"wide">>, [Descriptor], fun([N]) -> {score, N} end),
    ?assert(lists:all(fun([N]) -> N >= Lo andalso N =< Lo + 1000 end, Values)),
    [#{<<"search">> := Search}] = reports(Directory),
    ?assertEqual(integer_to_binary(Lo + 1000), maps:get(<<"best">>, Search))
end).

budget_and_rejected_candidates_test() -> with_directory(fun(Directory) ->
    Ds = [<<"(int Int32 0 1000)">> || _ <- lists:seq(1, 10)],
    Values = trace(<<"budget">>, Ds, fun(Ns) -> {score, lists:sum(Ns)} end),
    ?assertEqual(400, length(Values)),
    Rejects = trace(<<"rejected">>, Ds, fun(_) -> none end),
    ?assertEqual(70, length(Rejects)),
    [R] = [R || #{<<"law">> := <<"rejected">>} = R <- reports(Directory)],
    ?assertMatch(#{<<"search">> := #{<<"accepted">> := 0, <<"best">> := null}}, R)
end).

failure_contains_seed_and_wire_inputs_test() -> with_directory(fun(Directory) ->
    Descriptor = <<"(int Int32 0 1000)">>,
    try lawspec_beam_search:climb(<<"broken">>, [Descriptor], fun(_) -> error(native_failure) end) of
        _ -> ?assert(false)
    catch error:{lawspec, {target_failed, <<"broken">>, {seed, 42}, {inputs, [Hex]}, {error, native_failure}}} ->
        {Table, D} = lawspec_beam_values:from_text(Descriptor),
        Value = lawspec_beam_values:decode(D, binary:decode_hex(Hex), Table),
        ?assert(Value >= 0 andalso Value =< 1000)
    end,
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"failed">>, <<"search">> := #{<<"tried">> := 1}}, Report)
end).

property_targets_keep_exact_statistics_test() -> with_directory(fun(Directory) ->
    Huge = 1 bsl 200,
    lawspec_beam_harness:run(<<"observed target">>, <<"property">>, [], fun() ->
        lists:foreach(fun(N) -> true = lawspec_beam_harness:sample(fun() -> {[], [], [], {score, N}} end,
            fun() -> true end) end, [Huge, Huge + 1, Huge - 1])
    end),
    [Report] = reports(Directory),
    ?assertEqual(#{<<"best">> => integer_to_binary(Huge + 1)}, maps:get(<<"target">>, Report)),
    ?assertEqual(3, maps:get(<<"cases">>, Report))
end).

%% The fixtures were collected from the existing JavaScript descriptor climb.
%% Compare every attempted value, including rejected candidates and moves.
vectors(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Cases = json:decode(Bytes),
    lists:foreach(fun(#{<<"label">> := Label, <<"seed">> := Seed, <<"descriptors">> := Ds, <<"tried">> := Expected}) ->
        with_directory(fun(_) ->
            os:putenv("LAWSPEC_SEED", binary_to_list(Seed)),
            Actual = trace(Label, Ds, fun(Values) -> {score, score(Values)} end),
            ?assertEqual(Expected, [lawspec_beam_values:render(Values) || Values <- Actual])
        end)
    end, Cases),
    io:format("~B descriptor climbs match every candidate of the portable runtime.~n", [length(Cases)]).

score(N) when is_integer(N) -> -(N - 37) * (N - 37);
score(Vs) when is_list(Vs) -> lists:sum([score(V) || V <- Vs]);
score({ls_data, _, Fields}) -> score(Fields);
score(_) -> 0.

trace(Label, Descriptors, Check) ->
    put(search_trace, []),
    ok = lawspec_beam_search:climb(Label, Descriptors, fun(V) ->
        put(search_trace, [V | get(search_trace)]), Check(V)
    end),
    lists:reverse(erase(search_trace)).

with_directory(Test) -> lawspec_beam_harness_tests:with_directory(Test).
reports(Directory) -> lawspec_beam_harness_tests:reports(Directory).
