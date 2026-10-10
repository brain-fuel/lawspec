%% @doc Shared resource lifetime, isolation, concurrency and cancellation.
%% ref:REQ-law-primitives ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(lawspec_beam_resources_tests).
-include_lib("eunit/include/eunit.hrl").

sequential_users_reset_one_value_and_release_on_run_close_test() ->
    Test = self(),
    {Run, Value, Worker} = lawspec_beam_resources:with_run(fun(Run) ->
        {Value, First} = borrow(Run, key, Test, false),
        Worker = event(acquired),
        true = ets:insert(Value, {contents, old}),
        ok = lawspec_beam_resources:checkin(First),
        {Value, Second} = borrow(Run, key, Test, false),
        ?assertEqual(Worker, event(reset)),
        ?assertEqual([], ets:tab2list(Value)),
        ok = lawspec_beam_resources:checkin(Second),
        no_event(), {Run, Value, Worker}
    end),
    ?assertEqual(Worker, event(released)),
    ?assertNot(is_process_alive(Run)),
    ?assertNot(is_process_alive(Worker)),
    ?assertEqual(undefined, ets:info(Value)).

body_failure_returns_lease_and_restores_nested_run_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        ?assertEqual(Run, lawspec_beam_resources:current()),
        ?assertThrow(case_failed, shared(key, Test, false, fun(_) -> throw(case_failed) end)),
        _ = event(acquired),
        shared(key, Test, false, fun(_) -> ok end),
        _ = event(reset),
        lawspec_beam_resources:with_run(fun(Inner) ->
            ?assertNotEqual(Run, Inner), ?assertEqual(Inner, lawspec_beam_resources:current())
        end),
        ?assertEqual(Run, lawspec_beam_resources:current())
    end),
    _ = event(released),
    ?assertError({lawspec, missing_resource_run}, lawspec_beam_resources:current()).

final_release_reverses_actual_acquisition_order_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        lists:foreach(fun(Key) ->
            {_, Lease} = lawspec_beam_resources:checkout(Run, Key, #{},
                fun() -> Key end, fun(_) -> ok end, fun(Value) -> Test ! {closed_key, Value} end, false),
            lawspec_beam_resources:checkin(Lease)
        end, [b, a, c])
    end),
    ?assertEqual([c, a, b], [receive {closed_key, Key} -> Key after 1000 -> error(not_released) end || _ <- [1,2,3]]).

exclusive_waiter_cannot_enter_before_last_owner_returns_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        {Value, Lease = {Entry, _}} = borrow(Run, exclusive, Test, false),
        _ = event(acquired),
        Next = spawn(fun() ->
            {NextValue, NextLease} = borrow(Run, exclusive, Test, false),
            Test ! {next_lease, self(), NextValue},
            receive return -> lawspec_beam_resources:checkin(NextLease) end
        end),
        wait(fun() -> queue:len(maps:get(waiting, sys:get_state(Entry))) =:= 1 end),
        no_event(),
        lawspec_beam_resources:checkin(Lease),
        _ = event(reset),
        receive {next_lease, Next, Value} -> ok after 1000 -> error(waiter_not_admitted) end,
        join(Next, fun() -> Next ! return end)
    end), _ = event(released).

concurrent_users_overlap_and_reset_only_when_idle_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        {Value, First} = borrow(Run, concurrent, Test, true),
        _ = event(acquired),
        Users = [spawn(fun() ->
            {Value, Lease} = borrow(Run, concurrent, Test, true),
            Test ! {holding, self()}, receive return -> lawspec_beam_resources:checkin(Lease) end
        end) || _ <- lists:seq(1, 10)],
        lists:foreach(fun(Pid) -> receive {holding, Pid} -> ok after 1000 -> error(not_concurrent) end end, Users),
        no_event(),
        lawspec_beam_resources:checkin(First),
        {Value, Overlap} = borrow(Run, concurrent, Test, true),
        no_event(),
        lists:foreach(fun(Pid) -> join(Pid, fun() -> Pid ! return end) end, Users),
        lawspec_beam_resources:checkin(Overlap),
        {Value, Fresh} = borrow(Run, concurrent, Test, true),
        _ = event(reset), lawspec_beam_resources:checkin(Fresh)
    end), _ = event(released).

same_case_can_borrow_twice_without_resetting_its_live_value_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        {Value, One} = borrow(Run, reentrant, Test, false),
        _ = event(acquired),
        {Value, Two} = borrow(Run, reentrant, Test, false),
        no_event(),
        lawspec_beam_resources:checkin(Two), lawspec_beam_resources:checkin(One)
    end), _ = event(released).

killed_borrower_returns_its_exclusive_lease_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        User = spawn(fun() ->
            {_, Lease} = borrow(Run, death, Test, false),
            Test ! {lease, Lease}, receive never -> ok end
        end),
        _ = event(acquired),
        receive {lease, _} -> ok after 1000 -> error(no_lease) end,
        join(User, fun() -> exit(User, kill) end),
        {_, Next} = borrow(Run, death, Test, false),
        _ = event(reset), lawspec_beam_resources:checkin(Next)
    end), _ = event(released).

cancelled_queued_caller_never_acquires_or_resets_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        {_, First = {Entry, _}} = borrow(Run, queue, Test, false),
        _ = event(acquired),
        Queued = spawn(fun() -> borrow(Run, queue, Test, false), Test ! unexpected_admission end),
        wait(fun() -> queue:len(maps:get(waiting, sys:get_state(Entry))) =:= 1 end),
        join(Queued, fun() -> exit(Queued, kill) end),
        lawspec_beam_resources:checkin(First),
        wait(fun() -> queue:is_empty(maps:get(waiting, sys:get_state(Entry))) end),
        no_event()
    end), _ = event(released).

failed_acquisition_allows_a_later_attempt_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        ?assertThrow(acquire_failed, lawspec_beam_resources:checkout(Run, retry, #{},
            fun() -> throw(acquire_failed) end, fun(_) -> error(reset_unacquired) end,
            fun(_) -> Test ! unexpected_release end, false)),
        no_event(),
        {_, Lease} = borrow(Run, retry, Test, false),
        _ = event(acquired), lawspec_beam_resources:checkin(Lease)
    end), _ = event(released).

failed_reset_does_not_grant_a_lease_or_lose_final_release_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        Borrow = fun() -> lawspec_beam_resources:checkout(Run, reset_failure, #{},
            fun() -> put(resets, 0), resource_value(Test) end,
            fun(V) ->
                N = get(resets), put(resets, N + 1),
                case N of 0 -> error(reset_failed); _ -> ets:delete_all_objects(V) end
            end, fun(V) -> release_value(Test, V) end, false) end,
        {Value, First} = Borrow(), _ = event(acquired), lawspec_beam_resources:checkin(First),
        ?assertError(reset_failed, Borrow()),
        {Value, Last} = Borrow(), lawspec_beam_resources:checkin(Last)
    end), _ = event(released).

release_failure_still_releases_the_other_resources_test() ->
    Test = self(),
    Result = try lawspec_beam_resources:with_run(fun(Run) ->
        lists:foreach(fun(Key) ->
            {_, Lease} = lawspec_beam_resources:checkout(Run, Key, #{}, fun() -> Key end,
                fun(_) -> ok end, fun(K) ->
                    Test ! {closed_key, K}, case K of b -> throw(release_failed); _ -> ok end
                end, false),
            lawspec_beam_resources:checkin(Lease)
        end, [a,b,c])
    end) catch error:Reason -> Reason end,
    ?assertMatch({lawspec, {resource_cleanup_failed, [{b, {exception, throw, release_failed, _}}]}}, Result),
    ?assertEqual([c,b,a], [receive {closed_key, K} -> K after 1000 -> error(not_released) end || _ <- [1,2,3]]).

retained_handlers_outlive_each_original_case_test() ->
    Test = self(),
    {Run, Cell} = lawspec_beam_resources:with_run(fun(Run) ->
        {Cell, FirstValue} = lawspec_beam_effects:with_scope(#{}, #{}, fun(Schema) ->
            Cell = lawspec_beam_effects:native_cell(0),
            Acquire = fun() -> lawspec_beam_effects:native_write(Cell, 1), Cell end,
            Reset = fun(C) -> lawspec_beam_effects:native_write(C, lawspec_beam_effects:native_read(C) + 1) end,
            Release = fun(C) -> Test ! {final_counter, lawspec_beam_effects:native_read(C)} end,
            {Value, Lease} = lawspec_beam_resources:checkout(Run, handlers, Schema, Acquire, Reset, Release, false),
            lawspec_beam_resources:checkin(Lease), {Cell, Value}
        end),
        ?assert(is_process_alive(Cell)),
        {FirstValue, Next} = lawspec_beam_resources:checkout(Run, handlers, #{},
            fun() -> error(wrong_acquisition) end, fun(_) -> error(wrong_reset) end,
            fun(_) -> error(wrong_release) end, false),
        ?assertEqual(2, lawspec_beam_effects:native_read(Cell)),
        lawspec_beam_resources:checkin(Next), {Run, Cell}
    end),
    receive {final_counter, 2} -> ok after 1000 -> error(wrong_handler_context) end,
    ?assertNot(is_process_alive(Cell)), ?assertNot(is_process_alive(Run)).

workflow_context_lives_until_its_shared_resource_is_released_test() ->
    Test = self(),
    State = lawspec_beam_resources:with_run(fun(Run) ->
        State = lawspec_beam_workflow:with_virtual(7, fun(Runtime) ->
            State = maps:get(state, Runtime),
            {_, First} = lawspec_beam_resources:checkout(Run, policy, #{},
                fun() -> lawspec_beam_workflow:set_time(lawspec_beam_workflow:current(#{}), 41), value end,
                fun(_) -> lawspec_beam_workflow:sleep(lawspec_beam_workflow:current(#{}), 1) end,
                fun(_) -> Test ! {final_time, lawspec_beam_workflow:now(lawspec_beam_workflow:current(#{}))} end, false),
            lawspec_beam_resources:checkin(First), State
        end),
        ?assert(is_process_alive(State)),
        {_, Last} = borrow(Run, policy, Test, false),
        lawspec_beam_resources:checkin(Last), State
    end),
    receive {final_time, 42} -> ok after 1000 -> error(wrong_workflow_context) end,
    ?assertNot(is_process_alive(State)).

close_waits_for_live_borrowers_and_denies_new_requests_test() ->
    Test = self(), {ok, Run} = lawspec_beam_resources:start(),
    {_, Lease = {Entry, _}} = borrow(Run, held, Test, false), _ = event(acquired),
    Closer = spawn(fun() -> lawspec_beam_resources:close(Run), Test ! closed end),
    wait(fun() -> maps:get(frozen, sys:get_state(Entry)) end),
    ?assertError({lawspec, resource_run_closed}, borrow(Run, other, Test, false)),
    no_event(),
    lawspec_beam_resources:checkin(Lease), _ = event(released),
    receive closed -> ok after 1000 -> error(not_closed) end,
    wait(fun() -> not is_process_alive(Closer) end),
    ?assertNot(is_process_alive(Run)).

run_owner_death_drains_and_releases_test() ->
    Test = self(),
    Owner = spawn(fun() -> {ok, Run} = lawspec_beam_resources:start(), Test ! {run, Run}, receive never -> ok end end),
    Run = receive {run, R} -> R after 1000 -> error(no_run) end,
    {_, Lease} = borrow(Run, owned, Test, false), _ = event(acquired),
    Monitor = monitor(process, Run),
    join(Owner, fun() -> exit(Owner, kill) end),
    lawspec_beam_resources:checkin(Lease), _ = event(released),
    receive {'DOWN', Monitor, process, Run, normal} -> ok after 1000 -> error(run_leaked) end.

same_key_cannot_change_concurrency_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        {_, Lease} = borrow(Run, key, Test, false), _ = event(acquired),
        ?assertError({lawspec, {resource_concurrency_mismatch, key}}, borrow(Run, key, Test, true)),
        lawspec_beam_resources:checkin(Lease)
    end), _ = event(released).

run_context_crosses_native_async_workers_test() ->
    Test = self(),
    lawspec_beam_resources:with_run(fun(Run) ->
        ?assertEqual(Run, lawspec_beam_runtime:async_call(fun lawspec_beam_resources:current/0)),
        ?assertEqual(ok, lawspec_beam_runtime:async_call(fun() -> shared(context, Test, false, fun(_) -> ok end) end)),
        _ = event(acquired)
    end), _ = event(released).

cancelled_acquisition_keeps_handlers_until_final_release_test() ->
    Test = self(),
    {ok, Run} = lawspec_beam_resources:start(),
    Caller = spawn(fun() -> lawspec_beam_effects:with_scope(#{}, #{}, fun(Schema) ->
        Cell = lawspec_beam_effects:native_cell(7),
        _ = lawspec_beam_resources:checkout(Run, acquiring, Schema, fun() ->
            Test ! {acquiring, self(), Cell}, receive finish_acquire -> Cell end
        end, fun(_) -> ok end, fun(C) -> Test ! {released_counter, lawspec_beam_effects:native_read(C)} end, false)
    end) end),
    {Worker, Cell} = receive {acquiring, W, C} -> {W, C} after 1000 -> error(no_acquisition) end,
    join(Caller, fun() -> exit(Caller, kill) end),
    ?assert(is_process_alive(Cell)),
    Worker ! finish_acquire,
    lawspec_beam_resources:close(Run),
    receive {released_counter, 7} -> ok after 1000 -> error(cancelled_resource_leaked) end,
    ?assertNot(is_process_alive(Worker)), ?assertNot(is_process_alive(Cell)).

killed_registry_still_releases_owned_entries_test() ->
    Test = self(), {ok, Run} = lawspec_beam_resources:start(),
    {Value, Lease = {Entry, _}} = borrow(Run, registry, Test, false),
    Worker = event(acquired),
    Monitor = monitor(process, Entry),
    join(Run, fun() -> exit(Run, kill) end),
    lawspec_beam_resources:checkin(Lease),
    ?assertEqual(Worker, event(released)),
    receive {'DOWN', Monitor, process, Entry, normal} -> ok after 1000 -> error(entry_leaked) end,
    ?assertNot(is_process_alive(Worker)), ?assertEqual(undefined, ets:info(Value)).

killed_entry_releases_its_value_and_run_reports_failure_test() ->
    Test = self(), {ok, Run} = lawspec_beam_resources:start(),
    {Value, Lease = {Entry, _}} = borrow(Run, damaged, Test, false),
    Worker = event(acquired), lawspec_beam_resources:checkin(Lease),
    WorkerMonitor = monitor(process, Worker),
    join(Entry, fun() -> exit(Entry, kill) end),
    ?assertEqual(Worker, event(released)),
    receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok after 1000 -> error(worker_leaked) end,
    ?assertEqual(undefined, ets:info(Value)),
    Result = try lawspec_beam_resources:close(Run) catch error:Reason -> Reason end,
    ?assertMatch({lawspec, {resource_cleanup_failed, [_ | _]}}, Result).

run_close_joins_cleanup_after_a_resource_coordinator_dies_test() ->
    Test = self(), {ok, Run} = lawspec_beam_resources:start(),
    {Value, Lease = {Entry, _}} = lawspec_beam_resources:checkout(Run, damaged, #{},
        fun() -> ets:new(damaged, [public]) end, fun(_) -> ok end,
        fun(Store) -> Test ! {release_started, self()}, receive finish_release -> ets:delete(Store) end end, false),
    lawspec_beam_resources:checkin(Lease),
    join(Entry, fun() -> exit(Entry, kill) end),
    Worker = receive {release_started, W} -> W after 1000 -> error(no_release) end,
    try
        Closer = spawn(fun() -> Test ! {closed, try lawspec_beam_resources:close(Run) catch error:R -> R end} end),
        wait(fun() -> try sys:get_state(Run) of
            #{cleanup_result := Result} when Result =/= none -> true;
            _ -> false
        catch exit:_ -> true end end),
        ?assert(is_process_alive(Run)),
        no_event(), Worker ! finish_release,
        receive {closed, Result} -> ?assertMatch({lawspec, {resource_cleanup_failed, [_ | _]}}, Result)
            after 1000 -> error(close_did_not_finish) end,
        wait(fun() -> not is_process_alive(Closer) end),
        ?assertNot(is_process_alive(Worker)), ?assertEqual(undefined, ets:info(Value))
    after Worker ! finish_release end.

native_eunit_fixture_shares_across_test_processes_test() ->
    Test = self(),
    Fixture = {setup, fun lawspec_beam_test_run:setup/0, fun lawspec_beam_test_run:cleanup/1,
        fun(_) -> [fun() -> shared(native, Test, false, fun(V) -> ?assertEqual([], ets:tab2list(V)), ets:insert(V, {a,b}) end) end
            || _ <- [1,2,3]] end},
    ?assertEqual(ok, eunit:test(Fixture, [no_tty])),
    Worker = event(acquired),
    ?assertEqual(Worker, event(reset)), ?assertEqual(Worker, event(reset)),
    ?assertEqual(Worker, event(released)),
    ?assertNot(is_process_alive(Worker)), ?assertEqual(undefined, whereis(lawspec_beam_resources)).

native_eunit_fixture_propagates_cleanup_failure_test() ->
    Fixture = {setup, fun lawspec_beam_test_run:setup/0, fun lawspec_beam_test_run:cleanup/1,
        fun(_) -> [fun() -> lawspec_beam_resources:with_shared(native_error, #{}, fun() -> value end,
            fun(_) -> ok end, fun(_) -> error(native_cleanup_failed) end, false, fun(_) -> ok end) end] end},
    ?assertEqual(error, eunit:test(Fixture, [no_tty])),
    ?assertEqual(undefined, whereis(lawspec_beam_resources)).

configured_suite_starts_a_fresh_pool_for_each_repetition_test() ->
    Test = self(),
    Owner = spawn(fun() -> receive done -> ok end end),
    try
        lawspec_beam_resources:configure_suite(Owner),
        One = lawspec_beam_resources:current(),
        shared(repeat, Test, false, fun(_) -> ok end),
        WorkerOne = event(acquired), lawspec_beam_resources:stop_suite(),
        ?assertEqual(WorkerOne, event(released)),
        Two = lawspec_beam_resources:current(), ?assertNotEqual(One, Two),
        shared(repeat, Test, false, fun(_) -> ok end),
        WorkerTwo = event(acquired), lawspec_beam_resources:stop_suite(),
        ?assertEqual(WorkerTwo, event(released)), ?assertNotEqual(WorkerOne, WorkerTwo)
    after
        lawspec_beam_resources:stop_suite(),
        join(Owner, fun() -> Owner ! done end)
    end,
    ?assertError({lawspec, missing_resource_run}, lawspec_beam_resources:current()).

borrow(Run, Key, Test, Concurrent) ->
    lawspec_beam_resources:checkout(Run, Key, #{}, fun() -> resource_value(Test) end,
        fun(V) -> reset_value(Test, V) end, fun(V) -> release_value(Test, V) end, Concurrent).
shared(Key, Test, Concurrent, Body) ->
    lawspec_beam_resources:with_shared(Key, #{}, fun() -> resource_value(Test) end,
        fun(V) -> reset_value(Test, V) end, fun(V) -> release_value(Test, V) end, Concurrent, Body).
resource_value(Test) ->
    Value = ets:new(shared_resource, [public]), Test ! {acquired, self()}, Value.
reset_value(Test, Value) -> ets:delete_all_objects(Value), Test ! {reset, self()}, ok.
release_value(Test, Value) -> ets:delete(Value), Test ! {released, self()}, ok.
event(Kind) -> receive {Kind, Pid} -> Pid after 1000 -> error({missing_event, Kind}) end.
no_event() -> receive Event -> error({unexpected_event, Event}) after 0 -> ok end.
join(Pid, Action) ->
    Monitor = monitor(process, Pid), Action(),
    receive {'DOWN', Monitor, process, Pid, _} -> ok after 1000 -> error({still_alive, Pid}) end.
wait(Check) -> wait(Check, 1000).
wait(_, 0) -> error(wait_timed_out);
wait(Check, Left) -> case Check() of true -> ok; false -> receive after 1 -> wait(Check, Left - 1) end end.
