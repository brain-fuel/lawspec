%% @doc The same accounting checks run through all three native frameworks.
%% Exercise real rejects, shrinks and rechecks, not a simulated property loop.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(lawspec_beam_harness_tests).
-include_lib("eunit/include/eunit.hrl").
-export([tests/1, run/1, with_directory/1, reports/1]).

tests(F) -> [{Name, fun() -> with_directory(fun(Directory) -> Test(Directory) end) end}
    || {Name, Test} <- [
        {"counts accepted native roots and ignores rejected tuples", fun(D) -> roots(F, D) end},
        {"native shrinking and rechecks do not change observations", fun(D) -> shrinks(F, D) end},
        {"cover fails independently of a passing law", fun(D) -> shortfall(F, D) end},
        {"coverage predicates with the same label remain independent", fun(D) -> same_label(F, D) end},
        {"empty generation preserves the native error and a zero count", fun(D) -> empty(F, D) end},
        {"zero cases cannot satisfy even zero percent coverage", fun zero/1},
        {"rounded display percentages cannot make coverage pass", fun exact_threshold/1},
        {"a later run starts fresh after failed adequacy", fun(D) -> fresh_run(F, D) end},
        {"nested and concurrent laws have isolated counters", fun isolated/1},
        {"an observation failure preserves its cause and freezes counts", fun(D) -> observer_failure(F, D) end},
        {"report paths preserve Unicode and do not collide", fun paths/1},
        {"a failed report cannot replace a property failure", fun reporting_failure/1},
        {"repeat keeps each native check and its coverage independent", fun(D) -> repeated(F, D) end},
        {"retry restarts the repeat sequence and records flaky history", fun(D) -> retried(F, D) end},
        {"exhausted retries preserve the native failure and seed", fun(D) -> exhausted_retries(F, D) end},
        {"coverage shortfalls are never retried", fun(D) -> no_cover_retry(F, D) end},
        {"an earlier repetition cannot hide a later coverage shortfall", fun(D) -> no_pooled_cover(F, D) end},
        {"a clean rerun clears the previous flaky status", fun(D) -> clean_rerun(F, D) end},
        {"invalid strategy values are never retried", fun(D) -> no_strategy_retry(F, D) end},
        {"a strategy discard limit is never retried", fun(D) -> no_discard_retry(F, D) end},
        {"caught harness errors cannot make a run pass", fun caught_abort/1},
        {"a failed repetition stops the remaining repetitions", fun repeat_failure/1},
        {"unobserved cases retain their original process and value", fun unobserved/1},
        {"retry retains separate targeted search reports", fun search_reports/1},
        {"known failures keep the first failed native check and stop", fun(D) -> expected_failure(F, D) end},
        {"a passing known-failing law fails with a removal diagnostic", fun(D) -> unexpected_pass(F, D) end},
        {"known failing cannot conceal a coverage shortfall", fun(D) -> expected_cover(F, D) end},
        {"known failing cannot conceal an invalid strategy", fun(D) -> expected_strategy(F, D) end},
        {"known failing cannot accept a law with no generated input", fun(D) -> expected_empty(F, D) end},
        {"retry success does not satisfy a known-failing annotation", fun(D) -> expected_flaky(F, D) end},
        {"known failure scopes isolate their reports", fun expected_nested/1},
        {"supervised checks keep native shrinking and resource ownership", fun(D) -> owned_shrinks(F, D) end},
        {"supervised native timeouts remain harness failures", fun(D) -> native_timeout(F, D) end}
    ]].

run(F) -> lists:foreach(fun({_, Test}) -> Test() end, tests(F)), ok.

owned_shrinks(F, Directory) ->
    Test = self(),
    Failure = failure(fun() -> lawspec_beam_harness:run(<<"owned shrinks">>, <<"property">>,
        [{100, <<"all">>}], #{timeout => 2000, resources => true}, fun() ->
            Generator = F:integer(5, 1000),
            F:check(<<"owned shrinks">>, F:forall(Generator, fun(Value) ->
                lawspec_beam_harness:sample(fun() -> {[true], [], []} end, fun() ->
                    lawspec_beam_resources:with_resource(#{}, fun() ->
                        Table = ets:new(owned_shrink, [private]), {self(), Table}
                    end, fun({Owner, Table}) ->
                        ?assertEqual(Owner, self()), ets:delete(Table), Test ! {released_shrink, Value, Owner}
                    end, fun({Owner, Table}) ->
                        lawspec_beam_resource:call(Owner, fun() -> ets:insert(Table, {value, Value}) end),
                        false
                    end)
                end)
            end), [quiet, {numtests, 20}, {constraint_tries, 100}, {max_shrinks, 100}])
        end) end),
    ?assertMatch({lawspec, _}, Failure),
    Values = shrink_events([]),
    ?assert(length(Values) > 1), ?assertEqual(5, lists:last(Values)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 1, <<"outcome">> := <<"failed">>}, Report),
    ?assertNot(maps:is_key(<<"failureKind">>, Report)).

shrink_events(Values) ->
    receive {released_shrink, Value, Owner} ->
        ?assertNot(is_process_alive(Owner)), shrink_events([Value | Values])
    after 0 -> lists:reverse(Values) end.

native_timeout(F, Directory) ->
    Failure = failure(fun() -> lawspec_beam_harness:run(<<"native timeout">>, <<"property">>, [],
        #{timeout => 100, retries => 3}, fun() -> F:check(<<"native timeout">>,
            F:forall(F:exactly(0), fun(_) -> receive never -> true end end),
            [quiet, {numtests, 1}, {constraint_tries, 100}, {max_shrinks, 100}]) end) end),
    ?assertEqual({lawspec, {test_timeout, <<"native timeout">>, 100}}, Failure),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"outcome">> := <<"failed">>, <<"failureKind">> := <<"harness">>}, Report).

roots(F, Directory) ->
    put(draws, 0),
    Generator = F:complete(F:refine_input(F:map(F:integer(0, 100), fun(V) ->
        put(draws, get(draws) + 1), V
    end), fun(V) -> V rem 2 =:= 0 end)),
    ?assertEqual(ok, native(F, <<"roots">>, Generator, fun(_) -> true end, fun(_) ->
        {[true, false], [{<<"even">>, true}, {<<"even">>, true}, {<<"never">>, false}],
            [<<"accepted">>, <<"accepted">>]}
    end, [{100, <<"accepted">>}, {0, <<"never">>}])),
    ?assert(erase(draws) > 60),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 60, <<"outcome">> := <<"passed">>,
        <<"classes">> := #{<<"even">> := 60, <<"never">> := 0},
        <<"labels">> := #{<<"accepted">> := 60}}, Report),
    [A, B] = maps:get(<<"cover">>, Report),
    ?assertMatch(#{<<"met">> := true, <<"observed">> := 100.0}, A),
    ?assertMatch(#{<<"met">> := true, <<"observed">> := +0.0}, B).

shrinks(F, Directory) ->
    put(callbacks, 0), put(observers, 0),
    Failure = failure(fun() -> native(F, <<"shrinks">>, F:integer(5, 10000), fun(_) ->
        put(callbacks, get(callbacks) + 1), false
    end, fun(_) ->
        put(observers, get(observers) + 1), {[true], [], [<<"root">>]}
    end, [{100, <<"root">>}]) end),
    ?assertMatch({lawspec, _}, Failure),
    Callbacks = erase(callbacks),
    ?assert(Callbacks > 1),
    ?assertEqual(Callbacks, erase(observers)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 1, <<"outcome">> := <<"failed">>,
        <<"labels">> := #{<<"root">> := 1}}, Report).

shortfall(F, Directory) ->
    Failure = failure(fun() -> native(F, <<"shortfall">>, F:exactly(0), fun(_) -> true end,
        fun(_) -> {[false], [], []} end, [{1, <<"unreachable">>}]) end),
    ?assertMatch({lawspec, {harness_failed, <<"shortfall">>, {unmet_cover, [_]}}}, Failure),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 60, <<"outcome">> := <<"failed">>,
        <<"cover">> := [#{<<"met">> := false, <<"observed">> := +0.0}]}, Report).

same_label(F, Directory) ->
    _ = failure(fun() -> native(F, <<"same label">>, F:exactly(0), fun(_) -> true end,
        fun(_) -> {[true, false], [], []} end, [{100, <<"same">>}, {1, <<"same">>}]) end),
    [Report] = reports(Directory),
    [A, B] = maps:get(<<"cover">>, Report),
    ?assertMatch(#{<<"met">> := true, <<"observed">> := 100.0}, A),
    ?assertMatch(#{<<"met">> := false, <<"observed">> := +0.0}, B).

empty(F, Directory) ->
    Generator = F:complete(F:refine_input(F:exactly(0), fun(_) -> false end)),
    Failure = failure(fun() -> native(F, <<"empty">>, Generator, fun(_) -> true end,
        fun(_) -> error(observer_called) end, [{0, <<"none">>}]) end),
    ?assertMatch({lawspec, _}, Failure),
    ?assertNotMatch({lawspec, {harness_failed, _, _}}, Failure),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 0, <<"outcome">> := <<"failed">>,
        <<"cover">> := [#{<<"met">> := false}]}, Report).

zero(Directory) ->
    ?assertError({lawspec, {harness_failed, <<"zero">>, {unmet_cover,
        [#{label := <<"no random cases">>, required := 0, observed := +0.0, met := false}]}}},
        lawspec_beam_harness:run(<<"zero">>, <<"statistics">>, [{0, <<"no random cases">>}], fun() -> ok end)),
    [Report] = reports(Directory),
    ?assertEqual(0, maps:get(<<"cases">>, Report)).

exact_threshold(Directory) ->
    _ = failure(fun() -> lawspec_beam_harness:run(<<"rounding">>, <<"rounding">>, [{100, <<"all">>}], fun() ->
        lists:foreach(fun(N) -> lawspec_beam_harness:sample(fun() -> {[N > 0], [], []} end,
            fun() -> true end) end, lists:seq(0, 20000))
    end) end),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 20001, <<"cover">> :=
        [#{<<"met">> := false, <<"observed">> := 100.0, <<"hits">> := 20000, <<"cases">> := 20001}],
        <<"outcome">> := <<"failed">>}, Report).

fresh_run(F, Directory) ->
    Observe = fun(_) -> {[true], [], []} end,
    _ = failure(fun() -> native(F, <<"again">>, F:exactly(0), fun(_) -> true end,
        fun(_) -> {[false], [], []} end, [{100, <<"all">>}]) end),
    ok = native(F, <<"again">>, F:exactly(0), fun(_) -> true end, Observe, [{100, <<"all">>}]),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 60, <<"outcome">> := <<"passed">>,
        <<"cover">> := [#{<<"met">> := true}]}, Report).

isolated(Directory) ->
    Parent = self(),
    One = fun(Label, N) -> lawspec_beam_harness:run(Label, Label, [], fun() ->
        lists:foreach(fun(_) -> true = lawspec_beam_harness:sample(fun() -> {[], [], [Label]} end,
            fun() -> true end) end, lists:seq(1, N))
    end) end,
    lawspec_beam_harness:run(<<"outer">>, <<"outer">>, [], fun() ->
        true = lawspec_beam_harness:sample(fun() -> {[], [], []} end, fun() -> One(<<"inner">>, 2), true end),
        Workers = [spawn_monitor(fun() -> One(integer_to_binary(N), N), Parent ! {finished, self()} end) || N <- [3, 4]],
        lists:foreach(fun({Pid, Ref}) ->
            receive {finished, Pid} -> ok after 1000 -> error(worker_timeout) end,
            receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> error(worker_down_timeout) end
        end, Workers),
        true = lawspec_beam_harness:sample(fun() -> {[], [], []} end, fun() -> true end)
    end),
    Counts = maps:from_list([{maps:get(<<"law">>, R), maps:get(<<"cases">>, R)} || R <- reports(Directory)]),
    ?assertEqual(#{<<"outer">> => 2, <<"inner">> => 2, <<"3">> => 3, <<"4">> => 4}, Counts),
    ?assertError({lawspec, harness_observation_outside_run}, lawspec_beam_harness:sample(fun() -> {[], [], []} end, fun() -> true end)).

observer_failure(F, Directory) ->
    put(observers, 0),
    Failure = failure(fun() -> native(F, <<"broken observation">>, F:integer(5, 10000), fun(_) -> true end,
        fun(_) -> put(observers, get(observers) + 1), error(broken_observation) end, []) end),
    ?assertMatch({lawspec, _}, Failure),
    ?assert(erase(observers) >= 1),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"cases">> := 1, <<"outcome">> := <<"failed">>}, Report).

paths(Directory) ->
    Names = [<<"../same:a">>, <<"../same/a">>, unicode:characters_to_binary("雪/é")],
    lists:foreach(fun(Name) -> lawspec_beam_harness:run(Name, Name, [], fun() ->
        lawspec_beam_harness:sample(fun() -> {[], [], [Name]} end, fun() -> true end)
    end) end, Names),
    ?assertEqual(lists:sort(Names), lists:sort([maps:get(<<"law">>, R) || R <- reports(Directory)])),
    {ok, Files} = file:list_dir(Directory),
    ?assertEqual(3, length(Files)),
    ?assert(lists:all(fun(P) -> filename:extension(P) =:= ".json" end, Files)).

reporting_failure(Directory) ->
    Path = filename:join(Directory, "not-a-directory"),
    ok = file:write_file(Path, <<>>),
    os:putenv("LAWSPEC_STATS", Path),
    try
        ?assertError(original_property_failure, lawspec_beam_harness:run(<<"broken report">>, <<"broken report">>, [],
            fun() -> error(original_property_failure) end))
    after os:putenv("LAWSPEC_STATS", Directory) end.

repeated(F, Directory) ->
    put(harness_runs, 0),
    controlled(F, <<"repeat">>, #{repeat => 3}, fun(_) -> true end, fun(_) -> {[true], [], []} end,
        [{100, <<"all">>}]),
    ?assertEqual(3, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"repeat">> := 3, <<"outcome">> := <<"passed">>, <<"cases">> := 10}, Report),
    Runs = maps:get(<<"runs">>, Report),
    ?assertEqual([1, 2, 3], [maps:get(<<"repetition">>, R) || R <- Runs]),
    ?assert(lists:all(fun(R) -> maps:get(<<"cases">>, R) =:= 10 end, Runs)),
    ?assert(lists:all(fun(R) -> [#{<<"met">> := Met}] = maps:get(<<"cover">>, R), Met end, Runs)).

retried(F, Directory) ->
    put(harness_runs, 0),
    controlled(F, <<"retry">>, #{repeat => 3, retries => 1}, fun(_) -> get(harness_runs) =/= 2 end,
        fun(_) -> {[true], [], []} end, [{100, <<"all">>}]),
    ?assertEqual(5, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 2, <<"repeat">> := 3, <<"outcome">> := <<"flaky">>, <<"cases">> := 10}, Report),
    Runs = maps:get(<<"runs">>, Report),
    ?assertEqual([{1, 1}, {1, 2}, {2, 1}, {2, 2}, {2, 3}],
        [{maps:get(<<"attempt">>, R), maps:get(<<"repetition">>, R)} || R <- Runs]),
    ?assertEqual([10, 1, 10, 10, 10], [maps:get(<<"cases">>, R) || R <- Runs]),
    ?assertEqual([<<"passed">>, <<"failed">>, <<"passed">>, <<"passed">>, <<"passed">>],
        [maps:get(<<"outcome">>, R) || R <- Runs]).

exhausted_retries(F, Directory) ->
    put(harness_runs, 0),
    Failure = failure(fun() -> controlled(F, <<"exhausted">>, #{retries => 2}, fun(_) -> false end,
        fun(_) -> {[], [], []} end, []) end),
    ?assertEqual(3, erase(harness_runs)),
    ?assertMatch({lawspec, _}, Failure),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~tp", [Failure])), <<"{seed,42}">>)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 3, <<"outcome">> := <<"failed">>, <<"cases">> := 1}, Report),
    ?assertEqual(3, length(maps:get(<<"runs">>, Report))).

no_cover_retry(F, Directory) ->
    put(harness_runs, 0),
    ?assertMatch({lawspec, {harness_failed, _, _}}, failure(fun() ->
        controlled(F, <<"shortfall retry">>, #{retries => 2}, fun(_) -> true end,
            fun(_) -> {[get(harness_runs) > 1], [], []} end, [{1, <<"later">>}]) end)),
    ?assertEqual(1, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"outcome">> := <<"failed">>}, Report).

no_pooled_cover(F, Directory) ->
    put(harness_runs, 0),
    ?assertMatch({lawspec, {harness_failed, _, _}}, failure(fun() ->
        controlled(F, <<"each repetition">>, #{repeat => 3, retries => 2}, fun(_) -> true end,
            fun(_) -> {[get(harness_runs) =/= 2], [], []} end, [{50, <<"each run">>}]) end)),
    ?assertEqual(2, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"outcome">> := <<"failed">>, <<"cases">> := 10}, Report),
    [First, Second] = maps:get(<<"runs">>, Report),
    ?assertMatch(#{<<"cover">> := [#{<<"hits">> := 10, <<"met">> := true}]}, First),
    ?assertMatch(#{<<"cover">> := [#{<<"hits">> := 0, <<"met">> := false}]}, Second).

clean_rerun(F, Directory) ->
    put(harness_runs, 0),
    Run = fun() -> controlled(F, <<"clean again">>, #{retries => 1}, fun(_) -> get(harness_runs) > 1 end,
        fun(_) -> {[], [], []} end, []) end,
    Run(),
    [Before] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"flaky">>, <<"attempts">> := 2}, Before),
    Run(),
    ?assertEqual(3, erase(harness_runs)),
    [After] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"passed">>, <<"attempts">> := 1, <<"runs">> := [_]}, After).

no_strategy_retry(F, Directory) ->
    no_generator_retry(F, Directory, fun() -> F:map(F:exactly(0), fun(Value) ->
        lawspec_beam_generators:check_drawn(<<"invalid">>, <<"input">>, fun(_) -> false end, Value)
    end) end).

no_discard_retry(F, Directory) ->
    no_generator_retry(F, Directory, fun() -> F:such_that(F:exactly(0), fun(_) -> false end, 2, <<"empty">>) end).

no_generator_retry(F, Directory, Generator) ->
    put(harness_runs, 0),
    Failure = failure(fun() -> lawspec_beam_harness:run(<<"generator">>, <<"generator">>, [],
        #{retries => 2, observed => false}, fun() ->
            put(harness_runs, get(harness_runs) + 1),
            F:check(<<"generator">>, F:forall(Generator(), fun(_) -> true end),
                [quiet, {numtests, 10}, {constraint_tries, 10}, {max_shrinks, 10}])
        end) end),
    ?assertMatch({lawspec, _}, Failure),
    ?assertEqual(1, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"outcome">> := <<"failed">>}, Report).

caught_abort(Directory) ->
    put(harness_runs, 0),
    ?assertError({lawspec, deliberately_invalid}, lawspec_beam_harness:run(<<"caught">>, <<"caught">>, [],
        #{retries => 3, observed => false}, fun() ->
            put(harness_runs, get(harness_runs) + 1),
            try lawspec_beam_harness:abort(deliberately_invalid) catch _:_ -> ok end
        end)),
    ?assertEqual(1, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"outcome">> := <<"failed">>}, Report).

repeat_failure(Directory) ->
    put(harness_runs, 0),
    ?assertThrow(second_repeat, lawspec_beam_harness:run(<<"second">>, <<"second">>, [],
        #{repeat => 4, observed => false}, fun() ->
            put(harness_runs, get(harness_runs) + 1),
            case get(harness_runs) of 2 -> throw(second_repeat); _ -> ok end
        end)),
    ?assertEqual(2, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"attempts">> := 1, <<"outcome">> := <<"failed">>, <<"runs">> := [_, _]}, Report).

unobserved(Directory) ->
    Table = ets:new(private_case_state, [private]),
    ets:insert(Table, {runs, 0}),
    try
        ?assertEqual(3, lawspec_beam_harness:run(<<"private">>, <<"private">>, [],
            #{repeat => 3, observed => false}, fun() -> ets:update_counter(Table, runs, 1) end)),
        [Report] = reports(Directory),
        ?assertNot(maps:is_key(<<"cases">>, Report)),
        ?assertMatch(#{<<"outcome">> := <<"passed">>}, Report)
    after ets:delete(Table) end.

search_reports(Directory) ->
    put(harness_runs, 0),
    lawspec_beam_harness:run(<<"search">>, <<"search search">>, [], #{retries => 1, observed => false}, fun() ->
        N = get(harness_runs) + 1, put(harness_runs, N),
        lawspec_beam_harness:record(#{law => <<"search">>, test => <<"search search">>,
            search => #{seed => <<"42">>, tried => N, best => integer_to_binary(N)}}),
        case N of 1 -> error(first_search_failed); _ -> ok end
    end),
    erase(harness_runs),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"flaky">>, <<"attempts">> := 2, <<"search">> := #{<<"tried">> := 2}}, Report),
    [First, Second] = maps:get(<<"runs">>, Report),
    ?assertMatch(#{<<"outcome">> := <<"failed">>, <<"search">> := #{<<"tried">> := 1}}, First),
    ?assertMatch(#{<<"outcome">> := <<"passed">>, <<"search">> := #{<<"tried">> := 2}}, Second).

expected_failure(F, Directory) ->
    put(reached_later_check, false),
    Law = <<"expected">>,
    lawspec_beam_harness:known_failing(Law, <<"expected known failing">>, <<"tracked bug">>, [
        {"example", fun() -> lawspec_beam_harness:run(Law, <<"example">>, [], #{observed => false}, fun() -> ok end) end},
        {timeout, 60, {"property", fun() -> native(F, Law, F:integer(5, 10000), fun(_) -> false end,
            fun(_) -> {[true], [], []} end, [{100, <<"root">>}]) end}},
        {"later", fun() -> put(reached_later_check, true) end}]),
    ?assertEqual(false, erase(reached_later_check)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"known-failing">>, <<"reason">> := <<"tracked bug">>}, Report),
    [Example, Property] = maps:get(<<"checks">>, Report),
    ?assertMatch(#{<<"outcome">> := <<"passed">>}, Example),
    ?assertMatch(#{<<"outcome">> := <<"failed">>, <<"cases">> := 1}, Property),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"failure">>, Report), <<"{seed,42}">>)).

unexpected_pass(F, Directory) ->
    Law = <<"fixed bug">>,
    ?assertError({lawspec, {known_failing_passed, Law, <<"old issue">>}},
        lawspec_beam_harness:known_failing(Law, <<"fixed bug known failing">>, <<"old issue">>, [
            {"property", fun() -> native(F, Law, F:exactly(5), fun(_) -> true end,
                fun(_) -> {[], [], []} end, []) end}])),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"known-failing-passed">>,
        <<"checks">> := [#{<<"outcome">> := <<"passed">>, <<"cases">> := 60}]}, Report).

expected_cover(F, Directory) ->
    Law = <<"expected cover">>,
    ?assertMatch({lawspec, {harness_failed, Law, _}}, failure(fun() ->
        lawspec_beam_harness:known_failing(Law, <<"expected cover known failing">>, <<"not a law failure">>, [
            {"property", fun() -> native(F, Law, F:exactly(5), fun(_) -> true end,
                fun(_) -> {[false], [], []} end, [{1, <<"missing">>}]) end}]) end)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"failed">>, <<"failureKind">> := <<"harness">>}, Report).

expected_strategy(F, Directory) ->
    Law = <<"expected strategy">>,
    ?assertMatch({lawspec, _}, failure(fun() ->
        lawspec_beam_harness:known_failing(Law, <<"expected strategy known failing">>, <<"not a law failure">>, [
            {"property", fun() -> native(F, Law,
                F:map(F:exactly(0), fun(V) -> lawspec_beam_generators:check_drawn(<<"bad">>, <<"n">>, fun(_) -> false end, V) end),
                fun(_) -> true end, fun(_) -> {[], [], []} end, []) end}]) end)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"failed">>, <<"failureKind">> := <<"harness">>}, Report).

expected_empty(F, Directory) ->
    Law = <<"expected empty">>,
    ?assertMatch({lawspec, _}, failure(fun() ->
        lawspec_beam_harness:known_failing(Law, <<"expected empty known failing">>, <<"not a law failure">>, [
            {"property", fun() -> native(F, Law, F:complete(F:refine_input(F:exactly(0), fun(_) -> false end)),
                fun(_) -> true end, fun(_) -> {[], [], []} end, []) end}]) end)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"failed">>, <<"failureKind">> := <<"harness">>}, Report).

expected_flaky(F, Directory) ->
    put(harness_runs, 0),
    Law = <<"expected flaky">>,
    ?assertError({lawspec, {known_failing_passed, Law, <<"old issue">>}},
        lawspec_beam_harness:known_failing(Law, <<"expected flaky known failing">>, <<"old issue">>, [
            {"property", fun() -> controlled(F, Law, #{retries => 1}, fun(_) -> get(harness_runs) > 1 end,
                fun(_) -> {[], [], []} end, []) end}])),
    ?assertEqual(2, erase(harness_runs)),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"outcome">> := <<"known-failing-passed">>,
        <<"checks">> := [#{<<"outcome">> := <<"flaky">>, <<"attempts">> := 2}]}, Report).

expected_nested(Directory) ->
    Law = <<"nested">>,
    Run = fun(Name, Test) -> {Name, fun() ->
        lawspec_beam_harness:run(Law, Name, [], #{observed => false}, Test)
    end} end,
    lawspec_beam_harness:known_failing(Law, <<"outer">>, <<"outer issue">>, [
        {"inner", fun() -> lawspec_beam_harness:known_failing(Law, <<"inner">>, <<"inner issue">>,
            [Run(<<"inside">>, fun() -> error(inner_error) end)]) end},
        Run(<<"outside">>, fun() -> error(outer_error) end)]),
    [Report] = reports(Directory),
    ?assertMatch(#{<<"test">> := <<"outer">>, <<"outcome">> := <<"known-failing">>,
        <<"checks">> := [#{<<"test">> := <<"inner">>, <<"outcome">> := <<"known-failing">>},
            #{<<"test">> := <<"outside">>, <<"outcome">> := <<"failed">>}]}, Report),
    lawspec_beam_harness:run(Law, <<"ordinary">>, [], #{observed => false}, fun() -> ok end),
    ?assertEqual(2, length(reports(Directory))).

controlled(F, Label, Options, Predicate, Observe, Covers) ->
    lawspec_beam_harness:run(Label, <<Label/binary, " property">>, Covers, Options, fun() ->
        put(harness_runs, get(harness_runs) + 1),
        F:check(Label, F:forall(F:integer(5, 10000), fun(Value) ->
            lawspec_beam_harness:sample(fun() -> Observe(Value) end, fun() -> Predicate(Value) end)
        end), [quiet, {numtests, 10}, {constraint_tries, 100}, {max_shrinks, 20}])
    end).

native(F, Label, Generator, Predicate, Observe, Covers) ->
    lawspec_beam_harness:run(Label, <<Label/binary, " property">>, Covers, fun() ->
        F:check(Label, F:forall(Generator, fun(Value) ->
            lawspec_beam_harness:sample(fun() -> Observe(Value) end, fun() -> Predicate(Value) end)
        end), [quiet, {numtests, 60}, {constraint_tries, 100}, {max_shrinks, 100}])
    end).

failure(Test) -> try Test(), error(expected_failure) catch error:Reason -> Reason end.

reports(Directory) -> [begin {ok, Bytes} = file:read_file(Path), json:decode(Bytes) end
    || Path <- filelib:wildcard(filename:join(Directory, "*.json"))].

with_directory(Test) ->
    Directory = filename:join([".artifacts", "beam-harness-statistics", os:getpid() ++ "-" ++
        integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_dir(filename:join(Directory, "placeholder")),
    Previous = [{Key, os:getenv(Key)} || Key <- ["LAWSPEC_STATS", "LAWSPEC_SEED"]],
    os:putenv("LAWSPEC_STATS", filename:absname(Directory)), os:putenv("LAWSPEC_SEED", "42"),
    try Test(Directory)
    after
        lists:foreach(fun({Key, false}) -> os:unsetenv(Key); ({Key, Value}) -> os:putenv(Key, Value) end, Previous),
        file:del_dir_r(Directory)
    end.
