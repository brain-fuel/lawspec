%% @doc Benchmarks evaluate callbacks, retain real failures, and never turn
%% their return values or timing thresholds into assertions.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(lawspec_beam_benchmark_tests).
-include_lib("eunit/include/eunit.hrl").

false_result_is_measured_in_the_same_process_test() ->
    with_stats(fun(D) ->
        Owner = self(), put(iterations, 0),
        Result = lawspec_beam_harness:benchmark(<<"unit">>, <<"false">>, fun() ->
            ?assertEqual(Owner, self()), put(iterations, get(iterations) + 1), false
        end),
        ?assertEqual(ok, Result),
        [Report] = reports(D),
        ?assertEqual(erase(iterations), maps:get(<<"iterations">>, Report)),
        ?assert(maps:get(<<"iterations">>, Report) >= 3),
        ?assert(maps:get(<<"iterations">>, Report) =< 100000),
        ?assert(maps:get(<<"mean_ns">>, Report) >= maps:get(<<"min_ns">>, Report)),
        ?assert(maps:get(<<"min_ns">>, Report) >= 0)
    end).

slow_body_gets_three_complete_iterations_test() ->
    with_stats(fun(D) ->
        put(iterations, 0),
        lawspec_beam_harness:benchmark(<<"unit">>, <<"slow">>, fun() ->
            put(iterations, get(iterations) + 1), timer:sleep(110)
        end),
        ?assertEqual(3, erase(iterations)),
        [Report] = reports(D),
        ?assert(maps:get(<<"min_ns">>, Report) >= 100000000)
    end).

native_failure_has_no_completed_timing_test() ->
    with_stats(fun(D) ->
        put(iterations, 0),
        ?assertThrow({native_failure, 42}, lawspec_beam_harness:benchmark(<<"unit">>, <<"fails">>, fun() ->
            put(iterations, get(iterations) + 1), throw({native_failure, 42})
        end)),
        ?assertEqual(1, erase(iterations)), ?assertEqual([], reports(D))
    end).

unit_and_unicode_names_have_distinct_records_test() ->
    with_stats(fun(D) ->
        Identities = [{<<"one">>, <<"same">>}, {<<"two">>, <<"same">>},
            {<<"one">>, <<"雪"/utf8>>}, {<<"one">>, <<"雲"/utf8>>}],
        lists:foreach(fun({Unit, Name}) -> lawspec_beam_harness:benchmark(Unit, Name, fun() -> ok end) end, Identities),
        ?assertEqual(lists:sort(Identities), lists:sort([{maps:get(<<"unit">>, R), maps:get(<<"benchmark">>, R)} || R <- reports(D)]))
    end).

with_stats(Body) ->
    D = filename:join(".artifacts/beam-benchmark-runtime", integer_to_list(erlang:unique_integer([positive]))),
    Previous = os:getenv("LAWSPEC_STATS"), os:putenv("LAWSPEC_STATS", D),
    try Body(D) after
        case Previous of false -> os:unsetenv("LAWSPEC_STATS"); _ -> os:putenv("LAWSPEC_STATS", Previous) end,
        file:del_dir_r(D)
    end.
reports(D) -> [json:decode(element(2, file:read_file(P))) || P <- filelib:wildcard(filename:join(D, "*.json"))].
