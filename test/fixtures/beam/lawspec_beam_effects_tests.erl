%% @doc Scoped state, recordings, cancellation and typed failure conformance.
%% ref:DEC-tests-cite-requirements ref:DEC-typed-core-boundary
-module(lawspec_beam_effects_tests).
-include_lib("eunit/include/eunit.hrl").

counter(Schema) ->
    lawspec_beam_effects:stateful(Schema, 0, #{
        add => fun(_, [N], State) -> {State + N, State + N} end,
        read => fun(_, [], State) -> {State, State} end,
        fail => fun(_, [], _) -> lawspec_beam_effects:raise_failure(payment, declined) end}).

perform(Schema, Op, Args) -> lawspec_beam_effects:perform(Schema, counter, Op, Args).
cell({lawspec_stateful, Pid, _}) -> Pid;
cell({lawspec_recording, Pid, _}) -> Pid.

scope(Body) -> lawspec_beam_effects:with_scope(#{}, #{counter => fun counter/1}, Body).

fresh_state_and_cleanup_test() ->
    lists:foreach(fun(_) ->
        Pid = scope(fun(S) ->
            ?assertEqual(0, perform(S, read, [])),
            ?assertEqual(3, perform(S, add, [3])),
            cell(lawspec_beam_effects:handler(S, counter))
        end),
        ?assertNot(is_process_alive(Pid))
    end, lists:seq(1, 10)).

nested_scopes_restore_state_and_keep_symbol_identity_test() ->
    Symbols = make_ref(),
    lawspec_beam_effects:with_scope(#{symbols => Symbols}, #{counter => fun counter/1}, fun(S) ->
        ?assertEqual(2, perform(S, add, [2])),
        lawspec_beam_effects:with_scope(S, #{counter => fun counter/1}, fun(Inner) ->
            ?assertEqual(Symbols, maps:get(symbols, Inner)),
            ?assertEqual(0, perform(Inner, read, [])),
            ?assertEqual(19, perform(Inner, add, [19]))
        end),
        ?assertEqual(2, perform(S, read, [])),
        ?assertThrow(abort, lawspec_beam_effects:with_scope(S, #{counter => fun counter/1}, fun(_) -> throw(abort) end)),
        ?assertEqual(2, perform(S, read, []))
    end).

clauses_see_current_scope_test() ->
    Delegating = lawspec_beam_effects:stateless(#{add => fun(S, Args) -> perform(S, add, Args) end}),
    Base = lawspec_beam_effects:install(#{}, #{forward => Delegating}),
    lawspec_beam_effects:with_scope(Base, #{counter => fun counter/1}, fun(S) ->
        ?assertEqual(4, lawspec_beam_effects:perform(S, forward, add, [4])),
        lawspec_beam_effects:with_scope(S, #{counter => fun counter/1}, fun(Inner) ->
            ?assertEqual(9, lawspec_beam_effects:perform(Inner, forward, add, [9]))
        end),
        ?assertEqual(4, perform(S, read, []))
    end).

parallel_calls_share_serial_state_test() ->
    scope(fun(S) ->
        Results = lawspec_beam_runtime:concurrently([fun() -> perform(S, add, [1]) end || _ <- lists:seq(1, 100)]),
        ?assertEqual(lists:seq(1, 100), lists:sort(Results)),
        ?assertEqual(100, perform(S, read, []))
    end).

failed_clause_keeps_previous_state_test() ->
    scope(fun(S) ->
        ?assertEqual(3, perform(S, add, [3])),
        ?assertEqual({left, declined}, lawspec_beam_effects:attempt(payment,
            fun() -> perform(S, fail, []) end, fun(V) -> {right, V} end, fun(V) -> {left, V} end)),
        ?assertEqual(3, perform(S, read, [])),
        ?assertEqual(5, perform(S, add, [2]))
    end).

recordings_include_failures_and_compare_logical_values_test() ->
    lawspec_beam_effects:with_scope(#{}, #{counter => fun(S) ->
        lawspec_beam_effects:recording(S, counter(S)) end}, fun(S) ->
        ?assertEqual(0, lawspec_beam_effects:count_calls(S, counter, add, any)),
        ?assertEqual(2, perform(S, add, [2])),
        ?assertEqual(4, perform(S, add, [2])),
        ?assertThrow({lawspec_failure, payment, declined}, perform(S, fail, [])),
        ?assertEqual(2, lawspec_beam_effects:count_calls(S, counter, add, any)),
        ?assertEqual(2, lawspec_beam_effects:count_calls(S, counter, add, [lawspec_beam_scalar:ratio(2, 1)])),
        ?assertEqual(0, lawspec_beam_effects:count_calls(S, counter, add, [3])),
        ?assertEqual(1, lawspec_beam_effects:count_calls(S, counter, fail, []))
    end).

missing_evidence_is_an_error_test() ->
    ?assertError({lawspec, {missing_handler, counter}}, perform(#{}, read, [])),
    ?assertError({lawspec, missing_handler_scope}, counter(#{})),
    scope(fun(S) ->
        ?assertError({lawspec, {recording_required, counter}}, lawspec_beam_effects:count_calls(S, counter, read, any)),
        ?assertError({lawspec, {missing_handler_operation, unknown}}, perform(S, unknown, []))
    end).

handler_exceptions_preserve_class_and_stack_test() ->
    scope(fun(S) ->
        Pid = cell(lawspec_beam_effects:handler(S, counter)),
        lists:foreach(fun(Class) ->
            try lawspec_beam_handler:call(Pid, fun(_) -> exception_origin(Class) end) of
                _ -> error(exception_disappeared)
            catch
                C:broken:Stack ->
                    ?assertEqual(Class, C),
                    ?assertMatch([{?MODULE, exception_origin, _, _} | _], Stack)
            end,
            ?assertEqual(0, perform(S, read, []))
        end, [error, exit, throw]),
        ?assertError({lawspec, {invalid_handler_result, invalid}}, lawspec_beam_handler:call(Pid, fun(_) -> invalid end)),
        ?assertEqual(1, perform(S, add, [1]))
    end).

exception_origin(error) -> erlang:error(broken);
exception_origin(exit) -> exit(broken);
exception_origin(throw) -> throw(broken).

partial_factory_failure_cleans_up_test() ->
    Test = self(),
    ?assertError(factory_failed, lawspec_beam_effects:with_scope(#{}, #{counter => fun(S) ->
        Test ! {allocated, cell(counter(S))}, erlang:error(factory_failed)
    end}, fun(_) -> unreachable end)),
    receive {allocated, Pid} -> ?assertNot(is_process_alive(Pid)) after 1000 -> error(no_handler) end.

recursive_state_call_fails_instead_of_waiting_test() ->
    lawspec_beam_effects:with_scope(#{}, #{counter => fun(S) ->
        lawspec_beam_effects:stateful(S, 0, #{recur => fun(Current, [], _) ->
            perform(Current, recur, []) end})
    end}, fun(S) ->
        ?assertError({lawspec, {recursive_handler_call, recur}}, perform(S, recur, []))
    end).

caller_death_cancels_busy_clause_and_queued_call_test() ->
    Test = self(),
    scope(fun(S) ->
        Pid = cell(lawspec_beam_effects:handler(S, counter)),
        Busy = spawn(fun() -> lawspec_beam_handler:call(Pid, fun(_) ->
            Test ! {busy_worker, self()}, receive forever -> {bad, 100} end end) end),
        Worker = receive {busy_worker, W} -> W after 1000 -> error(no_worker) end,
        WorkerMonitor = monitor(process, Worker),
        Queued = spawn(fun() -> lawspec_beam_handler:call(Pid, fun(_) ->
            Test ! unexpected_queued_execution, {bad, 200} end) end),
        wait_queued(Pid, 1000),
        QueuedMonitor = monitor(process, Queued),
        exit(Queued, kill),
        receive {'DOWN', QueuedMonitor, process, Queued, _} -> ok after 1000 -> error(queued_caller_alive) end,
        exit(Busy, kill),
        receive {'DOWN', WorkerMonitor, process, Worker, killed} -> ok after 1000 -> error(worker_leaked) end,
        ?assertEqual(0, perform(S, read, [])),
        receive unexpected_queued_execution -> error(dead_caller_ran) after 0 -> ok end,
        ?assertEqual(1, perform(S, add, [1]))
    end).

scope_owner_death_cancels_busy_clause_test() ->
    Test = self(),
    Owner = spawn(fun() -> scope(fun(S) ->
        Pid = cell(lawspec_beam_effects:handler(S, counter)),
        Test ! {owned, maps:get(lawspec_scope, S), Pid},
        lawspec_beam_handler:call(Pid, fun(_) ->
            Test ! {owned_worker, self()}, receive forever -> {bad, 1} end end)
    end) end),
    try
        {Scope, Handler} = receive {owned, SC, H} -> {SC, H} after 1000 -> error(no_scope) end,
        Worker = receive {owned_worker, W} -> W after 1000 -> error(no_worker) end,
        Monitors = [{P, monitor(process, P)} || P <- [Scope, Handler, Worker]],
        exit(Owner, kill),
        lists:foreach(fun({P, M}) ->
            receive {'DOWN', M, process, P, _} -> ok after 1000 -> error({process_leaked, P}) end
        end, Monitors)
    after exit(Owner, kill) end.

scope_exit_joins_busy_workers_test() ->
    Test = self(),
    {Caller, Worker} = scope(fun(S) ->
        Pid = cell(lawspec_beam_effects:handler(S, counter)),
        Caller = spawn(fun() ->
            try lawspec_beam_handler:call(Pid, fun(_) ->
                Test ! {closing_worker, self()}, receive forever -> {bad, 1} end end)
            catch exit:_ -> ok end
        end),
        Worker = receive {closing_worker, W} -> W after 1000 -> error(no_worker) end,
        {Caller, Worker}
    end),
    ?assertNot(is_process_alive(Worker)),
    Monitor = monitor(process, Caller),
    receive {'DOWN', Monitor, process, Caller, _} -> ok after 1000 -> error(caller_still_waiting) end.

killed_handler_cannot_leak_worker_test() ->
    Test = self(),
    scope(fun(S) ->
        Pid = cell(lawspec_beam_effects:handler(S, counter)),
        Caller = spawn(fun() ->
            try lawspec_beam_handler:call(Pid, fun(_) ->
                Test ! {linked_worker, self()}, receive forever -> {bad, 1} end end)
            catch exit:_ -> ok end
        end),
        Worker = receive {linked_worker, W} -> W after 1000 -> error(no_worker) end,
        Monitors = [{P, monitor(process, P)} || P <- [Caller, Worker]],
        exit(Pid, kill),
        lists:foreach(fun({P, M}) ->
            receive {'DOWN', M, process, P, _} -> ok after 1000 -> error({process_leaked, P}) end
        end, Monitors)
    end).

typed_attempt_catches_only_its_ability_test() ->
    Right = fun(V) -> {right, V} end, Left = fun(V) -> {left, V} end,
    ?assertEqual({right, 7}, lawspec_beam_effects:attempt(a, fun() -> 7 end, Right, Left)),
    ?assertEqual({left, bad}, lawspec_beam_effects:attempt(a,
        fun() -> lawspec_beam_effects:raise_failure(a, bad) end, Right, Left)),
    ?assertThrow({lawspec_failure, b, bad}, lawspec_beam_effects:attempt(a,
        fun() -> lawspec_beam_effects:raise_failure(b, bad) end, Right, Left)),
    ?assertError(broken, lawspec_beam_effects:attempt(a, fun() -> error(broken) end, Right, Left)),
    ?assertThrow({lawspec_failure, a, bad}, lawspec_beam_effects:attempt(a, fun() -> 7 end,
        fun(_) -> lawspec_beam_effects:raise_failure(a, bad) end, Left)).

native_failures_are_checked_before_becoming_typed_test() ->
    Convert = fun(V) -> lawspec_beam_scalar:validate(V, <<"Int8">>, 64) end,
    ?assertThrow({lawspec_failure, a, 7}, lawspec_beam_effects:native_failures(a, Convert,
        fun() -> lawspec_beam_effects:fail(7) end, [])),
    try lawspec_beam_effects:native_failures(a, Convert, fun() -> lawspec_beam_effects:fail(300) end, []) of
        _ -> error(invalid_failure_accepted)
    catch error:{lawspec, _} -> ok end,
    ?assertThrow({lawspec_failure, b, already_typed}, lawspec_beam_effects:native_failures(a, Convert,
        fun() -> lawspec_beam_effects:raise_failure(b, already_typed) end,
        [fun(_, _) -> error(typed_failure_was_remapped) end])).

native_exception_mappings_preserve_unmapped_exceptions_test() ->
    Maps = [fun(error, {declined, Message}) -> {ok, {ls_data, <<"Pay::Declined">>, [Message]}};
               (_, _) -> no_match end],
    ?assertThrow({lawspec_failure, pay, {ls_data, <<"Pay::Declined">>, [<<"declined">>]}},
        lawspec_beam_effects:native_failures(pay, fun(V) -> V end,
            fun() -> error({declined, <<"declined">>}) end, Maps)),
    ?assertThrow({declined, <<"different class">>}, lawspec_beam_effects:native_failures(pay,
        fun(V) -> V end, fun() -> throw({declined, <<"different class">>}) end, Maps)),
    try lawspec_beam_effects:native_failures(pay, fun(V) -> V end, fun() -> exception_origin(error) end, Maps) of
        _ -> error(unmapped_exception_disappeared)
    catch error:broken:Stack -> ?assertMatch([{?MODULE, exception_origin, _, _} | _], Stack) end.

wait_queued(_, 0) -> error(call_not_queued);
wait_queued(Pid, Remaining) ->
    case queue:len(maps:get(waiting, sys:get_state(Pid))) of
        1 -> ok;
        _ -> timer:sleep(1), wait_queued(Pid, Remaining - 1)
    end.

tagged_exception_mapping_checks_class_and_tag_test() ->
    Kind = {tag, declined},
    ?assertEqual({ok, <<"declined">>}, lawspec_beam_effects:match_exception(Kind, error, declined)),
    ?assertEqual({ok, <<"negative refund">>}, lawspec_beam_effects:match_exception(Kind, error,
        {declined, <<"negative refund">>})),
    ?assertEqual({ok, <<"{declined,42}">>}, lawspec_beam_effects:match_exception(Kind, error, {declined, 42})),
    lists:foreach(fun({Class, Reason}) ->
        ?assertEqual(no_match, lawspec_beam_effects:match_exception(Kind, Class, Reason))
    end, [{throw, declined}, {exit, declined}, {error, other},
        {error, {other, <<"declined">>}}, {error, <<"declined">>}, {error, {}}]),
    ?assertEqual(no_match, lawspec_beam_effects:match_exception({elixir, 'Elixir.Declined'}, error,
        #{'__struct__' => 'Elixir.Declined', '__exception__' => false})).
