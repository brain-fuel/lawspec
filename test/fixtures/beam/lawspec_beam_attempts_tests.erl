%% @doc Native timeout and hedge scheduling, results and owned-worker cleanup.
%% ref:DEC-tests-cite-requirements ref:DEC-domain-modeling-primitives
-module(lawspec_beam_attempts_tests).
-include_lib("eunit/include/eunit.hrl").

right(Value) -> {ls_data, <<"Either::Right">>, [Value]}.
left(Value) -> {ls_data, <<"Either::Left">>, [Value]}.
silent(_) -> ok.

ordinary_attempt_keeps_the_callers_mailbox_test() ->
    Tag = make_ref(), self() ! {Tag, unrelated},
    ?assertEqual(right(42), lawspec_beam_attempts:run(none, none, fun() -> right(42) end, fun silent/1)),
    receive {Tag, unrelated} -> ok after 0 -> error(unrelated_message_consumed) end,
    ?assertEqual(undefined, get({lawspec_beam_tasks, scopes})).

timeout_cancels_and_joins_the_body_test() ->
    Test = self(),
    ?assertEqual(lawspec_beam_policy:stage_failure(<<"TimedOut">>),
        lawspec_beam_attempts:run(50000, none, fun() ->
            Test ! {body, self()}, receive forever -> never end
        end, fun silent/1)),
    receive {body, Pid} -> ?assertNot(is_process_alive(Pid)) after 1000 -> error(body_not_started) end.

timeout_joins_nested_async_workers_test() ->
    Test = self(),
    ?assertEqual(lawspec_beam_policy:stage_failure(<<"TimedOut">>),
        lawspec_beam_attempts:run(50000, none, fun() ->
            lawspec_beam_runtime:async_call(fun() ->
                lawspec_beam_runtime:concurrently([fun() ->
                    Test ! {nested, self()}, receive forever -> never end
                end])
            end)
        end, fun silent/1)),
    receive {nested, Pid} -> ?assertNot(is_process_alive(Pid)) after 1000 -> error(nested_worker_not_started) end.

hedge_keeps_the_first_success_and_joins_the_loser_test() ->
    Test = self(), Count = atomics:new(1, []),
    Result = lawspec_beam_attempts:run(none, {1000, 2}, fun() ->
        case atomics:add_get(Count, 1, 1) of
            1 -> Test ! {loser, self()}, receive forever -> never end;
            2 -> right(winner)
        end
    end, fun(N) -> Test ! {hedge, N} end),
    ?assertEqual(right(winner), Result),
    ?assertEqual(2, atomics:get(Count, 1)),
    receive {hedge, 2} -> ok after 0 -> error(missing_hedge_event) end,
    receive {loser, Pid} -> ?assertNot(is_process_alive(Pid)) after 0 -> error(loser_not_started) end.

failed_attempts_start_the_next_hedge_without_waiting_test() ->
    Test = self(), Count = atomics:new(1, []),
    %% A long hedge delay with a short timeout succeeds only if failures
    %% immediately start the next attempt, as on every other target.
    Result = lawspec_beam_attempts:run(500000, {10000000, 3}, fun() ->
        left(atomics:add_get(Count, 1, 1))
    end, fun(N) -> Test ! {hedge, N} end),
    ?assertEqual(left(3), Result),
    ?assertEqual(3, atomics:get(Count, 1)),
    receive {hedge, 2} -> ok after 0 -> error(missing_second_event) end,
    receive {hedge, 3} -> ok after 0 -> error(missing_third_event) end.

all_failed_hedges_return_the_last_completed_failure_test() ->
    Test = self(), Count = atomics:new(1, []),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Result = lawspec_beam_attempts:run(none, {1000, 2}, fun() ->
            case atomics:add_get(Count, 1, 1) of
                1 -> Test ! {first, self()}, receive finish -> left(first) end;
                2 -> Test ! {second, self()}, left(second)
            end
        end, fun silent/1),
        Test ! {result, Result}
    end),
    First = receive {first, F} -> F after 1000 -> error(first_not_started) end,
    Second = receive {second, S} -> S after 1000 -> error(second_not_started) end,
    Finished = monitor(process, Second),
    receive {'DOWN', Finished, process, Second, _} -> ok after 1000 -> error(second_not_finished) end,
    receive {result, _} -> error(returned_early) after 10 -> ok end,
    First ! finish,
    receive {result, Result} -> ?assertEqual(left(first), Result) after 1000 -> error(no_result) end,
    receive {'DOWN', Monitor, process, Caller, normal} -> ok after 1000 -> error(caller_leaked) end.

exception_preserves_its_class_and_cancels_other_attempts_test() ->
    Test = self(), Count = atomics:new(1, []),
    ?assertThrow(native_failure, lawspec_beam_attempts:run(none, {1000, 2}, fun() ->
        case atomics:add_get(Count, 1, 1) of
            1 -> Test ! {loser, self()}, receive forever -> never end;
            2 -> throw(native_failure)
        end
    end, fun silent/1)),
    receive {loser, Pid} -> ?assertNot(is_process_alive(Pid)) after 0 -> error(loser_not_started) end,
    ?assertEqual(undefined, get({lawspec_beam_tasks, scopes})).

caller_death_closes_the_attempt_scope_test() ->
    Test = self(),
    Caller = spawn(fun() -> lawspec_beam_attempts:run(none, none, fun() ->
        [Scope | _] = get({lawspec_beam_tasks, scopes}),
        Test ! {body, self(), Scope}, receive forever -> never end
    end, fun silent/1) end),
    {Body, Scope} = receive {body, B, S} -> {B, S} after 1000 -> error(body_not_started) end,
    BM = monitor(process, Body), SM = monitor(process, Scope),
    exit(Caller, kill),
    receive {'DOWN', BM, process, Body, killed} -> ok after 1000 -> error(body_leaked) end,
    receive {'DOWN', SM, process, Scope, normal} -> ok after 1000 -> error(scope_leaked) end.
