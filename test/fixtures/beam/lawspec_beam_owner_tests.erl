%% @doc Dedicated resource owners survive test cancellation, with bounded
%% cleanup and native harness failures that cannot be retried or suppressed.
%% ref:REQ-law-primitives ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(lawspec_beam_owner_tests).
-include_lib("eunit/include/eunit.hrl").

private_state_is_used_through_its_owner_test() ->
    Test = self(),
    {Worker, Owner, Table} = run(#{resources => true}, fun() ->
        owned(Test, store, fun({Pid, T}) ->
            ?assertNotEqual(self(), Pid),
            ?assertEqual(Pid, ets:info(T, owner)),
            ?assertError(badarg, ets:insert(T, {value, 7})),
            ?assertEqual(7, lawspec_beam_resource:call(Pid, fun() ->
                true = ets:insert(T, {value, 7}), ets:lookup_element(T, value, 2)
            end)),
            {self(), Pid, T}
        end)
    end),
    ?assertNotEqual(Test, Worker),
    ?assertEqual({opened, store, Owner}, event()),
    ?assertEqual({closed, store, Owner}, event()),
    ?assertNot(is_process_alive(Worker)),
    ?assertNot(is_process_alive(Owner)),
    ?assertEqual(undefined, ets:info(Table)).

timeout_releases_nested_owners_in_reverse_order_test() ->
    Test = self(),
    ?assertError({lawspec, {test_timeout, <<"owner">>, 100}}, run(#{timeout => 100}, fun() ->
        owned(Test, first, fun(_) -> owned(Test, second, fun(_) ->
            Test ! {borrower, self()}, receive never -> ok end
        end) end)
    end)),
    {opened, first, First} = event(), {opened, second, Second} = event(),
    {borrower, Worker} = event(),
    ?assertEqual({closed, second, Second}, event()),
    ?assertEqual({closed, first, First}, event()),
    lists:foreach(fun(Pid) -> ?assertNot(is_process_alive(Pid)) end, [Worker, First, Second]).

timeout_joins_nested_async_borrowers_before_release_test() ->
    Test = self(),
    ?assertError({lawspec, {test_timeout, <<"owner">>, 100}}, run(#{timeout => 100}, fun() ->
        owned(Test, async, fun(_) -> lawspec_beam_runtime:async_call(fun() ->
            Test ! {child, self()}, receive never -> ok end
        end) end)
    end)),
    {opened, async, Owner} = event(), {child, Child} = event(),
    ?assertEqual({closed, async, Owner}, event()),
    ?assertNot(is_process_alive(Child)).

external_native_runner_cancellation_still_releases_test() ->
    Test = self(),
    Caller = spawn(fun() -> run(#{resources => true}, fun() ->
        owned(Test, external, fun(_) -> Test ! {borrower, self()}, receive never -> ok end end)
    end) end),
    {opened, external, Owner} = event(), {borrower, Worker} = event(),
    Ref = monitor(process, Owner), exit(Caller, kill),
    ?assertEqual({closed, external, Owner}, event()),
    receive {'DOWN', Ref, process, Owner, _} -> ok after 1000 -> error(owner_leaked) end,
    ?assertNot(is_process_alive(Worker)).

suite_close_waits_for_cancelled_case_cleanup_test() ->
    Test = self(), {ok, Suite} = lawspec_beam_resources:start_suite(),
    Caller = spawn(fun() -> run(#{resources => true}, fun() ->
        lawspec_beam_resources:with_resource(#{}, fun() -> Test ! started, value end,
            fun(_) -> receive after 50 -> Test ! released end end,
            fun(_) -> receive never -> ok end end)
    end) end),
    ?assertEqual(started, event()), exit(Caller, kill),
    ok = lawspec_beam_resources:close(Suite),
    ?assertEqual(released, event()), ?assertNot(is_process_alive(Suite)).

suite_close_reports_cancelled_case_cleanup_failure_test() ->
    Test = self(), {ok, Suite} = lawspec_beam_resources:start_suite(),
    Caller = spawn(fun() -> run(#{resources => true}, fun() ->
        lawspec_beam_resources:with_resource(#{}, fun() -> Test ! started, value end,
            fun(_) -> receive after 20 -> error(cleanup_failed) end end,
            fun(_) -> receive never -> ok end end)
    end) end),
    ?assertEqual(started, event()), exit(Caller, kill),
    ?assertMatch({lawspec, {resource_cleanup_failed, [_ | _]}}, failed(fun() -> lawspec_beam_resources:close(Suite) end)),
    ?assertNot(is_process_alive(Suite)).

hung_release_is_bounded_and_never_retried_test() ->
    Test = self(),
    Failure = failed(fun() -> run(#{resources => true, retries => 3, cleanup_timeout => 30}, fun() ->
        lawspec_beam_resources:with_resource(#{}, fun() -> Test ! {opened, self()}, value end,
            fun(_) -> Test ! {release, self()}, receive never -> ok end end, fun(_) -> ok end)
    end) end),
    ?assertMatch({lawspec, {test_cleanup_failed, <<"owner">>, _, _}}, Failure),
    ?assert(string:find(lists:flatten(io_lib:format("~tp", [Failure])), "resource_cleanup_timeout") =/= nomatch),
    {opened, Owner} = event(), ?assertEqual({release, Owner}, event()),
    ?assertNot(is_process_alive(Owner)), no_event().

hung_acquisition_is_bounded_without_releasing_an_unknown_value_test() ->
    Test = self(),
    Failure = failed(fun() -> run(#{timeout => 100, cleanup_timeout => 30}, fun() ->
        lawspec_beam_resources:with_resource(#{}, fun() ->
            Test ! {acquiring, self()}, receive never -> value end
        end, fun(_) -> Test ! wrongly_released end, fun(_) -> Test ! wrongly_entered end)
    end) end),
    ?assertMatch({lawspec, {test_cleanup_failed, <<"owner">>,
        {test, {error, {lawspec, {test_timeout, <<"owner">>, 100}}}}, _}}, Failure),
    {acquiring, Owner} = event(), ?assertNot(is_process_alive(Owner)), no_event().

cleanup_has_its_own_budget_after_test_timeout_test() ->
    Test = self(),
    ?assertError({lawspec, {test_timeout, <<"owner">>, 50}}, run(#{timeout => 50, cleanup_timeout => 500}, fun() ->
        lawspec_beam_resources:with_resource(#{}, fun() -> self() end,
            fun(Owner) ->
                ?assertEqual(Owner, self()),
                receive after 100 -> Test ! released end
            end, fun(_) -> receive never -> ok end end)
    end)),
    ?assertEqual(released, event()).

failed_later_acquisition_releases_the_earlier_owner_test() ->
    Test = self(),
    ?assertEqual(acquisition_failed, failed(fun() -> run(#{resources => true}, fun() ->
        owned(Test, first, fun(_) -> lawspec_beam_resources:with_resource(#{},
            fun() -> error(acquisition_failed) end, fun(_) -> error(wrongly_released) end, fun(_) -> ok end)
        end)
    end) end)),
    {opened, first, Owner} = event(), ?assertEqual({closed, first, Owner}, event()).

release_failure_cannot_be_caught_into_a_pass_test() ->
    Test = self(),
    ?assertMatch({lawspec, {test_cleanup_failed, <<"owner">>, _, _}}, failed(fun() ->
        run(#{resources => true, retries => 3}, fun() ->
            try lawspec_beam_resources:with_resource(#{}, fun() -> value end,
                fun(_) -> Test ! release_attempt, error(release_failed) end, fun(_) -> ok end)
            catch _:_ -> ok end,
            ok
        end)
    end)),
    ?assertEqual(release_attempt, event()), no_event().

known_failing_cannot_conceal_timeout_or_cleanup_failure_test() ->
    lists:foreach(fun(Body) ->
        Failure = failed(fun() -> lawspec_beam_harness:known_failing(<<"owner">>, <<"expected">>, <<"bug">>,
            [{"case", fun() -> run(#{timeout => 50, cleanup_timeout => 30}, Body) end}]) end),
        ?assertMatch({lawspec, _}, Failure)
    end, [fun() -> receive never -> ok end end,
        fun() -> lawspec_beam_resources:with_resource(#{}, fun() -> value end,
            fun(_) -> error(release_failed) end, fun(_) -> ok end) end]).

shared_release_is_also_bounded_test() ->
    Test = self(), {ok, Run} = lawspec_beam_resources:start(30),
    {_, Lease} = lawspec_beam_resources:checkout(Run, shared, #{}, fun() -> Test ! {owner, self()}, value end,
        fun(_) -> ok end, fun(_) -> receive never -> ok end end, false),
    lawspec_beam_resources:checkin(Lease),
    ?assertMatch({lawspec, {resource_cleanup_failed, [_ | _]}}, failed(fun() -> lawspec_beam_resources:close(Run) end)),
    {owner, Owner} = event(), ?assertNot(is_process_alive(Owner)), ?assertNot(is_process_alive(Run)).

native_observations_survive_worker_completion_and_timeout_test() ->
    lawspec_beam_harness_tests:with_directory(fun(Directory) ->
        ?assertEqual(true, lawspec_beam_harness:run(<<"owner">>, <<"observed">>, [{100, <<"all">>}],
            #{timeout => 1000}, fun() -> lawspec_beam_harness:sample(fun() -> {[true], [], []} end, fun() -> true end) end)),
        [#{<<"cases">> := 1, <<"outcome">> := <<"passed">>}] = lawspec_beam_harness_tests:reports(Directory),
        _ = failed(fun() -> lawspec_beam_harness:run(<<"owner">>, <<"observed">>, [{100, <<"all">>}],
            #{timeout => 100}, fun() ->
                lawspec_beam_harness:sample(fun() -> {[true], [], []} end, fun() -> true end),
                receive never -> ok end
            end) end),
        [#{<<"cases">> := 1, <<"outcome">> := <<"failed">>, <<"failureKind">> := <<"harness">>}] =
            lawspec_beam_harness_tests:reports(Directory)
    end).

owned(Test, Key, Body) ->
    lawspec_beam_resources:with_resource(#{}, fun() ->
        Table = ets:new(owner_private, [private]), Test ! {opened, Key, self()}, {self(), Table}
    end, fun({Owner, Table}) ->
        ?assertEqual(Owner, self()), true = ets:delete(Table), Test ! {closed, Key, self()}
    end, Body).
run(Options, Body) -> lawspec_beam_harness:run(<<"owner">>, <<"owner">>, [], Options#{observed => false}, Body).
failed(Body) -> try Body(), error(unexpected_success) catch error:Reason -> Reason end.
event() -> receive Event -> Event after 1000 -> error(missing_event) end.
no_event() -> receive Event -> error({unexpected_event, Event}) after 0 -> ok end.
