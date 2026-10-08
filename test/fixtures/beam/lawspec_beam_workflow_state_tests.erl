%% @doc Workflow state is isolated, atomic and owned by its live callers.
%% ref:DEC-tests-cite-requirements ref:DEC-domain-modeling-primitives
-module(lawspec_beam_workflow_state_tests).
-include_lib("eunit/include/eunit.hrl").

scope(Body) ->
    {ok, State} = lawspec_beam_workflow_state:start(#{seed => 0}),
    try Body(State) after lawspec_beam_workflow_state:stop(State) end.
call(State, Request) -> lawspec_beam_workflow_state:call(State, Request).
admit() -> {ls_data, <<"lawspec.resilience::type::Gate::Admit">>, []}.
reject() -> {ls_data, <<"lawspec.resilience::type::Gate::Reject">>, []}.
bulkhead(Limit) -> #{kind => bulkhead, start => fun(_) -> 0 end,
    admit => fun(N, _) ->
        {Next, Decision} = case N < Limit of true -> {N + 1, admit()}; false -> {N, reject()} end,
        {ls_data, <<"Step">>, [Next, Decision]}
    end,
    finish => fun(N, _, _) -> N - 1 end}.

clock_random_and_trace_are_owned_by_the_runtime_test() ->
    scope(fun(S) ->
        ?assertEqual(0, call(S, now)),
        ok = call(S, {sleep, 12}), ok = call(S, {sleep, -2}),
        ?assertEqual(12, call(S, now)),
        ok = call(S, {set_time, 123}), ?assertEqual(123, call(S, now)),
        ?assertEqual(16294208416658607535 rem 101, call(S, {jitter, full, 100, 0, 0})),
        ok = call(S, {event, first}), ok = call(S, {event, second}),
        ?assertEqual([first, second], call(S, trace))
    end),
    scope(fun(S) -> ?assertEqual(0, call(S, now)), ?assertEqual([], call(S, trace)) end).

cache_compares_logical_values_and_expires_test() ->
    scope(fun(S) ->
        Key = {ls_data, <<"Pair">>, [1, <<"abc">>]},
        Same = {ls_data, <<"Pair">>, [lawspec_beam_scalar:ratio(2, 2), <<"abc">>]},
        ok = call(S, {cache, stage, Key, original, 10, 100}),
        ?assertEqual({some, original}, call(S, {cached, stage, Same, 109})),
        ?assertEqual(none, call(S, {cached, stage, Same, 110})),
        ok = call(S, {cache, stage, Key, old, 200, 100}),
        ok = call(S, {cache, stage, Same, replacement, 201, 100}),
        ?assertEqual({some, replacement}, call(S, {cached, stage, Key, 202})),
        ?assertEqual(none, call(S, {cached, other_stage, Key, 202}))
    end).

compensation_frames_keep_reverse_completion_order_test() ->
    scope(fun(S) ->
        Outer = call(S, new_frame), Inner = call(S, new_frame),
        ok = call(S, {undo, Outer, first, first_undo}),
        ok = call(S, {undo, Inner, nested, nested_undo}),
        ok = call(S, {undo, Outer, second, second_undo}),
        ?assertEqual([{nested, nested_undo}], call(S, {take_frame, Inner})),
        ?assertEqual([{second, second_undo}, {first, first_undo}], call(S, {take_frame, Outer})),
        ?assertEqual([], call(S, {take_frame, Outer})),
        ?assertEqual(#{}, maps:get(monitors, sys:get_state(S)))
    end).

parallel_gate_admissions_are_atomic_test() ->
    Test = self(),
    scope(fun(S) ->
        Gate = bulkhead(2),
        Workers = [spawn_monitor(fun() ->
            Ref = call(S, {new_stage, shared, 0}),
            Decision = call(S, {gate, Ref, Gate, 0}),
            Test ! {decision, self(), Decision},
            receive finish -> ok end,
            ok = call(S, {finish_stage, Ref, 0, true})
        end) || _ <- lists:seq(1, 30)],
        Decisions = [receive {decision, P, D} -> D after 1000 -> error(no_admission) end || {P, _} <- Workers],
        ?assertEqual(2, length([D || D <- Decisions, D =:= admit()])),
        lists:foreach(fun({P, M}) -> P ! finish,
            receive {'DOWN', M, process, P, normal} -> ok after 1000 -> error(worker_leaked) end
        end, Workers),
        ?assertEqual(0, maps:get({shared, bulkhead}, maps:get(states, sys:get_state(S)))),
        ?assertEqual(#{}, maps:get(stages, sys:get_state(S)))
    end).

cancelled_callers_release_their_gate_and_frames_test() ->
    Test = self(),
    scope(fun(S) ->
        Gate = bulkhead(1),
        {Worker, Monitor} = spawn_monitor(fun() ->
            _Frame = call(S, new_frame),
            Ref = call(S, {new_stage, shared, 0}),
            Test ! {decision, call(S, {gate, Ref, Gate, 0})},
            receive forever -> never end
        end),
        receive {decision, Decision} -> ?assertEqual(admit(), Decision) after 1000 -> error(no_admission) end,
        exit(Worker, kill), receive {'DOWN', Monitor, process, Worker, killed} -> ok end,
        Ref = call(S, {new_stage, shared, 1}),
        ?assertEqual(admit(), call(S, {gate, Ref, Gate, 1})),
        ok = call(S, {finish_stage, Ref, 1, true}),
        ?assertEqual(#{}, maps:get(stages, sys:get_state(S))),
        ?assertEqual(#{}, maps:get(frames, sys:get_state(S)))
    end).

failing_gate_callback_preserves_state_test() ->
    scope(fun(S) ->
        Ref = call(S, {new_stage, shared, 0}),
        Gate = bulkhead(1),
        Broken = Gate#{admit := fun(_, _) -> error(broken_gate) end},
        ?assertError(broken_gate, call(S, {gate, Ref, Broken, 0})),
        ?assertEqual(#{}, maps:get(states, sys:get_state(S))),
        ?assertEqual(admit(), call(S, {gate, Ref, Gate, 0})),
        ok = call(S, {finish_stage, Ref, 0, false})
    end).
