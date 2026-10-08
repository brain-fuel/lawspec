%% @doc Workflow policy composition, clocks and concurrent compensation.
%% ref:DEC-tests-cite-requirements ref:DEC-domain-modeling-primitives
-module(lawspec_beam_workflow_tests).
-include_lib("eunit/include/eunit.hrl").

right(Value) -> {ls_data, <<"Either::Right">>, [Value]}.
left(Value) -> {ls_data, <<"Either::Left">>, [Value]}.
failed(Kind) -> lawspec_beam_policy:stage_failure(Kind).
scope(Body) -> lawspec_beam_workflow:with_runtime(#{clock => virtual}, Body).
run(Policy, Body) -> lawspec_beam_workflow:run_stage(#{}, maps:merge(#{stage => <<"step">>}, Policy), Body, ls_unit).
trace(Runtime) -> lawspec_beam_workflow:trace(Runtime).
retry(Strategy, Attempts) -> #{strategy => Strategy, attempts => Attempts, jitter => none, 'when' => none}.
gate(Kind, Decision, Finish) -> #{kind => Kind, start => fun(_) -> 0 end,
    admit => fun(State, _) -> {ls_data, <<"Step">>, [State, Decision]} end,
    finish => Finish, wait => none}.
admit() -> {ls_data, <<"lawspec.resilience::type::Gate::Admit">>, []}.
reject() -> {ls_data, <<"lawspec.resilience::type::Gate::Reject">>, []}.
wait(Delay) -> {ls_data, <<"lawspec.resilience::type::Gate::WaitFor">>, [Delay]}.
counter() -> atomics:new(1, []).
next(Counter) -> atomics:add_get(Counter, 1, 1).
value(Counter) -> atomics:get(Counter, 1).

retry_delays_and_trace_test() ->
    Count = counter(),
    scope(fun(Runtime) ->
        Policy = #{retry => retry({exponential, 100, 2, none}, 4)},
        ?assertEqual(left(4), run(Policy, fun() -> left(next(Count)) end)),
        ?assertEqual(700, lawspec_beam_workflow:now(Runtime)),
        ?assertEqual([{<<"start">>, <<"step">>, 1, false}, {<<"finish">>, <<"step">>, 1, false},
            {<<"sleep">>, <<"step">>, 100, true}, {<<"start">>, <<"step">>, 2, false},
            {<<"finish">>, <<"step">>, 2, false}, {<<"sleep">>, <<"step">>, 200, true},
            {<<"start">>, <<"step">>, 3, false}, {<<"finish">>, <<"step">>, 3, false},
            {<<"sleep">>, <<"step">>, 400, true}, {<<"start">>, <<"step">>, 4, false},
            {<<"finish">>, <<"step">>, 4, false}], trace(Runtime))
    end).

retry_condition_receives_the_unwrapped_error_test() ->
    Count = counter(), Conditions = counter(),
    scope(fun(_) ->
        Error = {ls_data, <<"lawspec.resilience::type::StageFailure::StepFailed">>, [declined]},
        Retry = (retry(immediate, 9))#{'when' := fun(Reason) ->
            ?assertEqual(declined, Reason), next(Conditions), false end},
        ?assertEqual(left(Error), run(#{retry => Retry, wraps => true}, fun() -> next(Count), left(Error) end)),
        ?assertEqual(1, value(Count)), ?assertEqual(1, value(Conditions)),
        ?assertEqual(failed(<<"CircuitOpen">>), run(#{retry => Retry, wraps => true},
            fun() -> failed(<<"CircuitOpen">>) end)),
        ?assertEqual(1, value(Conditions))
    end).

custom_retry_can_stop_and_receives_previous_wait_test() ->
    Count = counter(),
    scope(fun(Runtime) ->
        Decide = fun
            (2, 1, 0) -> {wait, 13};
            (3, 2, 13) -> {wait, 29};
            (4, 3, 29) -> stop
        end,
        Policy = #{retry => retry({custom, Decide}, 0)},
        ?assertEqual(left(3), run(Policy, fun() -> left(next(Count)) end)),
        ?assertEqual(42, lawspec_beam_workflow:now(Runtime))
    end).

test_runtime_is_fresh_per_case_and_disables_admission_and_cache_test() ->
    Gate = gate(limit, reject(), none), Count = counter(),
    lists:foreach(fun(_) -> lawspec_beam_workflow:with_test_runtime(fun() ->
        Runtime = lawspec_beam_workflow:current(#{}),
        ?assertEqual(0, lawspec_beam_workflow:now(Runtime)), ?assertEqual([], trace(Runtime)),
        Policy = #{gates => [Gate], cache => 1000},
        ?assertEqual(right(value(Count) + 1), run(Policy, fun() -> right(next(Count)) end)),
        ?assertEqual(right(value(Count) + 1), run(Policy, fun() -> right(next(Count)) end)),
        lawspec_beam_workflow:sleep(Runtime, 50)
    end) end, [first, second]),
    ?assertEqual(4, value(Count)).

nested_runtime_restores_context_even_after_exception_test() ->
    Before = get({lawspec_beam_workflow, runtime}),
    scope(fun(Outer) ->
        lawspec_beam_workflow:set_time(Outer, 100),
        ?assertThrow(stop, scope(fun(Inner) ->
            ?assertEqual(0, lawspec_beam_workflow:now(Inner)), throw(stop)
        end)),
        ?assertEqual(Outer, lawspec_beam_workflow:current(#{})),
        ?assertEqual(100, lawspec_beam_workflow:now(Outer))
    end),
    ?assertEqual(Before, get({lawspec_beam_workflow, runtime})).

gate_wait_is_bounded_and_can_be_unbounded_test() ->
    lists:foreach(fun({Bound, ExpectedTime, Expected}) ->
        scope(fun(Runtime) ->
            Gate = (gate(limit, admit(), none))#{wait := Bound,
                admit := fun(State, Now) -> {ls_data, <<"Step">>, [State,
                    case Now >= 30 of true -> admit(); false -> wait(10) end]} end},
            ?assertEqual(Expected, run(#{gates => [Gate]}, fun() -> right(ok) end)),
            ?assertEqual(ExpectedTime, lawspec_beam_workflow:now(Runtime))
        end)
    end, [{none, 0, failed(<<"RateLimited">>)}, {20, 20, failed(<<"RateLimited">>)},
        {30, 30, right(ok)}, {infinity, 30, right(ok)}]).

earlier_gates_are_finished_when_a_later_gate_rejects_test() ->
    Done = counter(),
    scope(fun(_) ->
        Breaker = gate(breaker, admit(), fun(State, _, Success) ->
            ?assertNot(Success), next(Done), State end),
        Limit = gate(limit, reject(), none),
        ?assertEqual(failed(<<"RateLimited">>), run(#{gates => [Breaker, Limit]},
            fun() -> error(rejected_body_ran) end)),
        ?assertEqual(1, value(Done))
    end).

gates_are_finished_once_after_retries_or_native_exceptions_test() ->
    Done = counter(), Count = counter(),
    scope(fun(Runtime) ->
        Gate = gate(breaker, admit(), fun(State, _, Success) ->
            case next(Done) of 1 -> ?assert(Success); 2 -> ?assertNot(Success) end, State end),
        ?assertEqual(right(ok), run(#{gates => [Gate], retry => retry(immediate, 3)},
            fun() -> case next(Count) of 1 -> left(retry); 2 -> right(ok) end end)),
        ?assertThrow(native_error, run(#{gates => [Gate]}, fun() -> throw(native_error) end)),
        ?assertEqual(2, value(Done)),
        State = sys:get_state(maps:get(state, Runtime)),
        ?assertEqual(#{}, maps:get(stages, State)), ?assertEqual(#{}, maps:get(monitors, State))
    end).

cache_uses_logical_equality_expires_and_skips_failures_test() ->
    Count = counter(),
    scope(fun(Runtime) ->
        Policy = #{stage => <<"cached">>, cache => 10},
        Run = fun(Input) -> lawspec_beam_workflow:run_stage(#{}, Policy, fun() -> right(next(Count)) end, Input) end,
        ?assertEqual(right(1), Run(1)), ?assertEqual(right(1), Run(lawspec_beam_scalar:ratio(2, 2))),
        ?assertEqual(right(2), Run(2)),
        lawspec_beam_workflow:sleep(Runtime, 10), ?assertEqual(right(3), Run(1)),
        Failure = fun() -> lawspec_beam_workflow:run_stage(#{}, Policy, fun() -> left(next(Count)) end, 3) end,
        ?assertEqual(left(4), Failure()), ?assertEqual(left(5), Failure()),
        ?assertEqual(1, length([ok || {<<"cached">>, _, _, _} <- trace(Runtime)]))
    end).

compensation_is_in_reverse_completion_order_and_infallible_stages_keep_their_value_test() ->
    Test = self(),
    scope(fun(Runtime) ->
        Stage = fun(Name, Result) -> run(#{stage => Name,
            compensate => fun(Value) -> Test ! {undo, Name, Value} end}, fun() -> Result end) end,
        ?assertEqual(left(stopped), lawspec_beam_workflow:run_workflow(#{}, fun() ->
            Stage(<<"first">>, right(1)),
            lawspec_beam_runtime:async_call(fun() -> Stage(<<"second">>, 2) end), left(stopped)
        end)),
        ?assertEqual([{undo, <<"second">>, 2}, {undo, <<"first">>, 1}],
            [receive {undo, _, _} = Undo -> Undo after 1000 -> error(missing_undo) end || _ <- [1, 2]]),
        ?assertEqual([<<"second">>, <<"first">>], [Name || {<<"compensate">>, Name, _, _} <- trace(Runtime)]),
        ?assertEqual(undefined, get({lawspec_beam_workflow, frame}))
    end).

cached_result_does_not_duplicate_compensation_test() ->
    Count = counter(),
    scope(fun(_) ->
        Policy = #{cache => 100, compensate => fun(_) -> next(Count) end},
        lawspec_beam_workflow:run_workflow(#{}, fun() ->
            run(Policy, fun() -> right(1) end),
            run(Policy, fun() -> error(cached_body_ran) end), left(stopped)
        end),
        ?assertEqual(1, value(Count))
    end).

nested_workflow_frames_do_not_mix_test() ->
    Test = self(),
    scope(fun(_) ->
        Stage = fun(Name) -> run(#{stage => Name, compensate => fun(_) -> Test ! {undo, Name} end}, fun() -> right(ok) end) end,
        lawspec_beam_workflow:run_workflow(#{}, fun() ->
            Stage(outer),
            lawspec_beam_workflow:run_workflow(#{}, fun() -> Stage(inner), left(failed) end),
            Stage(later), left(failed)
        end),
        ?assertEqual([inner, later, outer], [receive {undo, N} -> N after 1000 -> error(missing_undo) end || _ <- [1, 2, 3]])
    end).

parallel_workflow_frames_remain_separate_test() ->
    Test = self(), Barrier = counter(),
    scope(fun(Runtime) ->
        Results = lawspec_beam_runtime:concurrently([fun() ->
            ?assertEqual(Runtime, lawspec_beam_workflow:current(#{})),
            lawspec_beam_workflow:run_workflow(#{}, fun() ->
                Caller = self(),
                run(#{stage => N, compensate => fun(_) -> Test ! {undo, N, self(), Caller} end}, fun() -> right(N) end),
                next(Barrier), await_count(Barrier, 2), left(N)
            end)
        end || N <- [first, second]]),
        ?assertEqual([left(first), left(second)], Results),
        Undos = [receive {undo, N, Caller, Caller} -> N after 1000 -> error(crossed_frame) end || _ <- [1, 2]],
        ?assertEqual([first, second], lists:sort(Undos))
    end).
await_count(Count, Expected) ->
    case value(Count) of Expected -> ok; _ -> receive after 1 -> await_count(Count, Expected) end end.

success_and_untyped_exceptions_do_not_compensate_test() ->
    Count = counter(),
    scope(fun(_) ->
        Stage = fun() -> run(#{compensate => fun(_) -> next(Count) end}, fun() -> right(ok) end) end,
        ?assertEqual(right(ok), lawspec_beam_workflow:run_workflow(#{}, Stage)),
        ?assertError(native_error, lawspec_beam_workflow:run_workflow(#{}, fun() -> Stage(), error(native_error) end)),
        ?assertEqual(0, value(Count)), ?assertEqual(undefined, get({lawspec_beam_workflow, frame}))
    end).

virtual_timeout_counts_reported_time_including_hedges_test() ->
    scope(fun(Runtime) ->
        Body = fun() -> lawspec_beam_workflow:sleep(Runtime, 10), right(ok) end,
        ?assertEqual(right(ok), run(#{timeout => 10}, Body)),
        ?assertEqual(failed(<<"TimedOut">>), run(#{timeout => 9}, Body)),
        Count = counter(),
        ?assertEqual(failed(<<"TimedOut">>), run(#{timeout => 25, hedge => {100, 3}}, fun() ->
            lawspec_beam_workflow:sleep(Runtime, 10),
            case next(Count) of 3 -> right(ok); _ -> left(again) end
        end)),
        ?assertEqual(3, value(Count)),
        ?assertEqual([2, 3], [N || {<<"hedge">>, _, N, _} <- trace(Runtime)])
    end).

timeout_retry_joins_the_previous_body_before_starting_another_test() ->
    Count = counter(), Test = self(), Workers = ets:new(policy_workers, [public]),
    try lawspec_beam_workflow:with_runtime(#{}, fun(_) ->
        ?assertEqual(right(done), run(#{timeout => 50000, wraps => true, retry => retry(immediate, 2)}, fun() ->
            case next(Count) of
                1 -> ets:insert(Workers, {first, self()}), Test ! {timed_out, self()}, receive forever -> never end;
                2 -> [{first, First}] = ets:lookup(Workers, first),
                    ?assertNot(is_process_alive(First)), right(done)
            end
        end)),
        receive {timed_out, Pid} -> ?assertNot(is_process_alive(Pid)) after 1000 -> error(first_attempt_missing) end,
        ?assertEqual(2, value(Count))
    end) after ets:delete(Workers) end.

custom_clock_and_native_facade_preserve_values_test() ->
    Time = counter(),
    Read = fun() -> value(Time) end,
    Sleep = fun(Delay) -> atomics:add(Time, 1, Delay), nil end,
    lawspec_beam_workflow:with_clock_callbacks(Read, Sleep, true, 123, fun(Runtime) ->
        ?assertEqual(nil, lawspec_beam_workflow:native_sleep(Runtime, 12)),
        ?assertEqual(12, lawspec_beam_workflow:now(Runtime)),
        ?assertEqual(left(retry), run(#{retry => retry({fixed, 4}, 2)}, fun() -> left(retry) end)),
        ?assertEqual(16, lawspec_beam_workflow:now(Runtime)),
        ?assertEqual([4], [N || {event, <<"sleep">>, <<"step">>, N, true} <-
            lawspec_beam_workflow:native_trace(Runtime)])
    end),
    lawspec_beam_workflow:with_virtual(0, fun(Runtime) ->
        ?assertEqual(nil, lawspec_beam_workflow:native_set_time(Runtime, 99)),
        ?assertEqual(99, lawspec_beam_workflow:now(Runtime))
    end).

installed_clock_supplies_time_but_explicit_runtime_keeps_its_clock_test() ->
    Clock = lawspec_beam_effects:stateless(#{
        <<"now">> => fun(_, []) -> {ls_data, <<"lawspec.time::type::Instant::Instant">>, [123]} end,
        <<"sleep">> => fun(_, _) -> ls_unit end}),
    Schema = #{lawspec_handlers => #{<<"lawspec.time::ability::Clock">> => Clock}},
    lawspec_beam_workflow:with_test_runtime(fun() ->
        ?assertEqual(123, lawspec_beam_workflow:now(lawspec_beam_workflow:current(Schema)))
    end),
    scope(fun(Runtime) ->
        ?assertEqual(Runtime, lawspec_beam_workflow:current(Schema)),
        ?assertEqual(0, lawspec_beam_workflow:now(Runtime))
    end).

default_clock_is_real_including_a_recording_test() ->
    Clock = lawspec_beam_defaults:handler(<<"lawspec.time::ability::Clock">>),
    lawspec_beam_workflow:with_test_runtime(fun() ->
        lists:foreach(fun(Handler) ->
            #{clock := #{virtual := IsVirtual}} = lawspec_beam_workflow:current(
                #{lawspec_handlers => #{<<"lawspec.time::ability::Clock">> => Handler}}),
            ?assertNot(IsVirtual)
        end, [Clock, {lawspec_recording, unused, Clock}])
    end).
