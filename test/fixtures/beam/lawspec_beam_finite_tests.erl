%% @doc Finite cover observations use native values, independent of generated
%% laws, and exercise lookup without expanding a large integer domain.
%% ref:DEC-planned-generation ref:DEC-tests-cite-requirements
-module(lawspec_beam_finite_tests).
-include_lib("eunit/include/eunit.hrl").
-export([indexed_fixture/1, factory_fixture/0]).

ordered_cases_test() ->
    Cover =
        {branches, [
            {
                {integers, 0, 2},
                {branches, [{{values, [fun(_) -> false end, fun(_) -> true end]}, {copies, 1}}]}
            }
        ]},
    Make = fun(Index, Factories) -> {Index, lawspec_beam_finite:values(none, Factories)} end,
    Expected = lists:zip(lists:seq(1, 6), [[A, B] || A <- lists:seq(0, 2), B <- [false, true]]),
    ?assertEqual(Expected, lawspec_beam_finite:cases(Cover, Make)),
    ?assertEqual(6, lawspec_beam_finite:count(Cover)),
    Plan = [{fixed, [before]}, {finite, Cover, Make}, {fixed, [after_case]}],
    All = [before] ++ Expected ++ [after_case],
    ?assertEqual(All, lawspec_beam_finite:plan_cases(Plan)),
    ?assertEqual(All, [lawspec_beam_finite:case_at(Plan, I) || I <- lists:seq(0, 7)]),
    ?assertError({lawspec, finite_case_index_out_of_range}, lawspec_beam_finite:case_at(Plan, 8)),
    ?assertError({lawspec, invalid_finite_case_index}, lawspec_beam_finite:case_at(Plan, -1)).

dependent_and_empty_cases_test() ->
    Cover =
        {branches, [
            {{integers, 1, 1}, {branches, [{{integers, 5, 5}, {copies, 2}}]}},
            {{integers, 2, 2}, {branches, [{{integers, 9, 9}, {copies, 1}}]}}
        ]},
    Make = fun(Index, Factories) -> {Index, lawspec_beam_finite:values(none, Factories)} end,
    ?assertEqual([{1, [1, 5]}, {2, [1, 5]}, {3, [2, 9]}], lawspec_beam_finite:cases(Cover, Make)),
    ?assertEqual([], lawspec_beam_finite:cases({branches, []}, Make)),
    ?assertEqual([{1, []}, {2, []}], lawspec_beam_finite:cases({copies, 2}, Make)).

large_ranges_and_early_stop_test() ->
    Maximum = (1 bsl 64) - 1,
    Make = fun(Index, Factories) -> {Index, lawspec_beam_finite:values(none, Factories)} end,
    ?assertEqual(
        [{1, [Maximum - 1]}, {2, [Maximum]}],
        lawspec_beam_finite:cases(
            {branches, [{{integers, Maximum - 1, Maximum}, {copies, 1}}]}, Make
        )
    ),
    Huge = 1 bsl 128,
    Cover = {branches, [{{integers, 0, Huge}, {copies, 1}}]},
    ?assertEqual({Huge + 1, [Huge]}, lawspec_beam_finite:case_at([{finite, Cover, Make}], Huge)),
    Seen = lawspec_beam_finite:fold(Cover, [], fun(Index, Factories, Acc) ->
        Next = [{Index, lawspec_beam_finite:values(none, Factories)} | Acc],
        case Index of
            3 -> {halt, Next};
            _ -> {continue, Next}
        end
    end),
    ?assertEqual([{3, [2]}, {2, [1]}, {1, [0]}], Seen).

fresh_factory_contexts_test() ->
    Factories = [fun(Scope) -> {symbol, Scope, same} end],
    First = make_ref(),
    Second = make_ref(),
    ?assertEqual(
        lawspec_beam_finite:values(First, Factories), lawspec_beam_finite:values(First, Factories)
    ),
    ?assertNotEqual(
        lawspec_beam_finite:values(First, Factories), lawspec_beam_finite:values(Second, Factories)
    ).

boundary_descriptions_keep_the_index_test() ->
    Long = unicode:characters_to_binary(lists:duplicate(250, 16#03BB)),
    First = lawspec_beam_finite:description(Long, 1),
    Second = lawspec_beam_finite:description(Long, 2),
    ?assertEqual(200, length(First)),
    ?assert(lists:suffix(" boundary 1", First)),
    ?assertNotEqual(First, Second).

indexed_lookup_avoids_rebuilding_factories_test() ->
    put(factory_calls, 0),
    ?assertEqual(
        {indexed, 7}, lawspec_beam_finite:lookup(?MODULE, indexed_fixture, factory_fixture, 7)
    ),
    ?assertEqual(0, get(factory_calls)),
    ?assertEqual(
        second, lawspec_beam_finite:lookup(?MODULE, missing_indexed_fixture, factory_fixture, 1)
    ),
    ?assertEqual(1, get(factory_calls)),
    ?assertEqual(
        [{timeout, 60, first}, {timeout, 60, second}],
        lawspec_beam_finite:with_timeout(60, [first, second])
    ).

indexed_fixture(Index) -> {indexed, Index}.
factory_fixture() ->
    put(factory_calls, get(factory_calls) + 1),
    [first, second].
