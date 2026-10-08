%% @doc Native OTP actors preserve stable handles, mailboxes and checkpoints.
%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(lawspec_beam_actors_tests).
-include_lib("eunit/include/eunit.hrl").
-export([init/1]).

init({native_parent, Spec}) ->
    {ok, {#{strategy => one_for_one}, [#{id => application_actors,
        start => {lawspec_beam_actors, start_link, [Spec]}, restart => permanent,
        shutdown => 5000, type => worker, modules => [lawspec_beam_actor_tree]}]}}.

otp_application_owns_stable_service_and_actor_handles_cross_schema_test() ->
    Child = (counter())#{metadata => #{name => account, setting => 42}},
    Spec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000,
        [{a, permanent, Child}, {b, permanent, Child}]),
    {ok, Application} = supervisor:start_link(?MODULE, {native_parent, Spec}),
    unlink(Application),
    [{application_actors, Service, worker, _}] = supervisor:which_children(Application),
    Sup = lawspec_beam_actors:from_process(Service),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    try
        HA = lawspec_beam_schema:handle(A, <<"Actor">>),
        HB = lawspec_beam_schema:handle(B, <<"Actor">>),
        Schema = lawspec_beam_schema:new([#{name => <<"Actor">>, parameters => 0,
            constructors => [], handle => true}], [], 64),
        ?assertEqual(HA, lawspec_beam_schema:from_native(A, {<<"Actor">>, []}, Schema)),
        ?assertEqual(A, lawspec_beam_schema:to_native(HA, {<<"Actor">>, []}, Schema)),
        ?assertNotEqual(HA, HB),
        ?assertEqual(#{name => account, setting => 42}, lawspec_beam_actors:metadata(A)),
        Old = lawspec_beam_actors:worker_pid(A),
        lawspec_beam_actors:crash(A),
        ?assertEqual(HA, lawspec_beam_schema:handle(lawspec_beam_actors:child(Sup, a), <<"Actor">>)),
        ?assertNotEqual(Old, lawspec_beam_actors:worker_pid(A)),
        ?assertMatch([{application_actors, Service, worker, _}], supervisor:which_children(Application)),
        ?assertEqual(#{name => account, setting => 42}, lawspec_beam_actors:metadata(A))
    after gen_server:stop(Application, normal, infinity) end,
    await_dead(Service).

linked_start_failure_has_native_otp_result_test() ->
    Spec = lawspec_beam_actors:actor(fun() -> error(start_broken) end, fun(S) -> S end),
    ?assertMatch({error, _}, lawspec_beam_actors:start_link(Spec)).

scoped_actor_api_closes_on_callback_exception_test() ->
    Test = self(),
    ?assertThrow(callback_broken, lawspec_beam_actors:with_spec(counter(), fun(A) ->
        {lawspec_actor, Tree, _} = A,
        Test ! {scope_owned, Tree, lawspec_beam_actors:worker_pid(A)},
        throw(callback_broken)
    end)),
    receive {scope_owned, Tree, Worker} -> await_dead(Tree), await_dead(Worker)
        after 1000 -> error(no_actor) end.

scoped_actor_api_closes_when_callback_owner_is_killed_test() ->
    Test = self(),
    Owner = spawn(fun() -> lawspec_beam_actors:with_spec(counter(), fun(A) ->
        {lawspec_actor, Tree, _} = A,
        Test ! {scope_owned, Tree, lawspec_beam_actors:worker_pid(A)},
        receive forever -> ok end
    end) end),
    {Tree, Worker} = receive {scope_owned, T, W} -> {T, W} after 1000 -> error(no_actor) end,
    exit(Owner, kill),
    await_dead(Tree), await_dead(Worker).

native_monitor_receive_selects_only_its_handle_test() ->
    A = lawspec_beam_actors:start(fun() -> 0 end),
    Other = {lawspec_actor, self(), [other]},
    self() ! ordinary_application_message,
    self() ! {lawspec_actor_event, Other, {stopped, none}},
    lawspec_beam_actors:monitor(A, self()),
    lawspec_beam_actors:crash(A, explicit_failure),
    ?assertEqual({ok, {crashed, explicit_failure}}, lawspec_beam_actors:receive_event(A, 1000)),
    ?assertEqual({error, nil}, lawspec_beam_actors:receive_event(A, 0)),
    receive ordinary_application_message -> ok after 0 -> error(application_message_lost) end,
    ?assertEqual({ok, stopped}, lawspec_beam_actors:receive_event(Other, 0)).

real_otp_workers_serialize_concurrent_messages_test() ->
    Actor = lawspec_beam_actors:start(fun() -> 0 end),
    {lawspec_actor, Tree, _} = Actor,
    Worker = lawspec_beam_actors:worker_pid(Actor),
    {status, Worker, {module, gen_server}, _} = sys:get_status(Worker),
    Root = maps:get(root, sys:get_state(Tree)),
    [{_, Worker, worker, [lawspec_beam_actor]}] = supervisor:which_children(Root),
    Test = self(),
    try
        [spawn(fun() -> Test ! {answer, bump(Actor)} end) || _ <- lists:seq(1, 100)],
        Values = [receive {answer, Value} -> Value after 2000 -> error(missing_reply) end || _ <- lists:seq(1, 100)],
        ?assertEqual(lists:seq(1, 100), lists:sort(Values)),
        ?assertEqual(100, lawspec_beam_actors:state(Actor)),
        ?assertEqual(Worker, lawspec_beam_actors:worker_pid(Actor))
    after lawspec_beam_actors:stop(Actor) end,
    await_dead(Tree), await_dead(Root), await_dead(Worker).

stop_refuses_new_messages_but_drains_accepted_tells_test() ->
    Actor = lawspec_beam_actors:start(fun() -> 0 end),
    Test = self(), Worker = lawspec_beam_actors:worker_pid(Actor),
    ok = lawspec_beam_actors:monitor(Actor, Test),
    lawspec_beam_actors:tell(Actor, fun(S) ->
        Test ! entered, receive continue -> {ok, S + 1} end
    end),
    receive entered -> ok after 1000 -> error(not_entered) end,
    lawspec_beam_actors:tell(Actor, fun(S) -> Test ! {drained, S + 1}, {ok, S + 1} end),
    spawn(fun() -> lawspec_beam_actors:stop(Actor), Test ! stopped end),
    wait(fun() -> not maps:get(accepting, actor_node(Actor)) end),
    ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:tell(Actor, fun(S) -> {ok, S} end)),
    Worker ! continue,
    receive {drained, 2} -> ok after 1000 -> error(queue_lost) end,
    receive stopped -> ok after 1000 -> error(stop_hung) end,
    receive {lawspec_actor_event, Actor, {stopped, none}} -> ok after 1000 -> error(no_stop_event) end,
    await_dead(Worker).

unsupervised_failure_keeps_original_cause_and_stops_test() ->
    Actor = lawspec_beam_actors:start(fun() -> 0 end),
    lawspec_beam_actors:monitor(Actor, self()),
    ?assertMatch({lawspec, {actor_crashed, {throw, broken, [_ | _]}}},
        failure(fun() -> lawspec_beam_actors:call(Actor, fun(_) -> throw(broken) end) end)),
    ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(Actor)),
    receive {lawspec_actor_event, Actor, {crashed, {throw, broken, _}}} -> ok
        after 1000 -> error(no_crash_event) end.

restart_preserves_checkpoint_and_waiting_messages_test() ->
    Spec = lawspec_beam_actors:actor(fun() -> 10 end, fun(S) -> S end),
    Sup = tree(one_for_one, 5, [{a, permanent, Spec}]),
    Actor = lawspec_beam_actors:child(Sup, a),
    Worker = lawspec_beam_actors:worker_pid(Actor), Test = self(),
    try
        ?assertEqual(11, bump(Actor)),
        spawn(fun() -> Test ! {failed, failure(fun() -> lawspec_beam_actors:call(Actor, fun(_) ->
            Test ! entered, receive continue -> error(broken) end
        end) end)} end),
        receive entered -> ok after 1000 -> error(not_entered) end,
        lawspec_beam_actors:tell(Actor, fun(S) -> {ok, S + 1} end),
        lawspec_beam_actors:tell(Actor, fun(S) -> {ok, S + 1} end),
        Worker ! continue,
        receive {failed, {lawspec, {actor_crashed, {error, broken, _}}}} -> ok
            after 1000 -> error(no_failure) end,
        ?assertEqual(13, lawspec_beam_actors:state(Actor)),
        ?assertNotEqual(Worker, lawspec_beam_actors:worker_pid(Actor)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

otp_restart_strategies_test() ->
    lists:foreach(fun({Strategy, Expected}) ->
        Sup = tree(Strategy, 5, [{a, permanent, counter()}, {b, permanent, counter()}, {c, permanent, counter()}]),
        Actors = [lawspec_beam_actors:child(Sup, Name) || Name <- [a, b, c]],
        Before = [lawspec_beam_actors:worker_pid(A) || A <- Actors],
        try
            [bump(A) || A <- Actors],
            lawspec_beam_actors:crash(lists:nth(2, Actors)),
            ?assertEqual(Expected, [lawspec_beam_actors:state(A) || A <- Actors]),
            After = [lawspec_beam_actors:worker_pid(A) || A <- Actors],
            ?assertEqual([V =:= 0 || V <- Expected], [P =/= Q || {P, Q} <- lists:zip(Before, After)])
        after lawspec_beam_actors:stop(Sup) end
    end, [{one_for_one, [1, 0, 1]}, {one_for_all, [0, 0, 0]}, {rest_for_one, [1, 0, 0]}]).

sibling_restart_follows_already_accepted_messages_test() ->
    lists:foreach(fun(Strategy) ->
        Test = self(),
        Sibling = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> Test ! {restart_checkpoint, S}, 0 end),
        Sup = tree(Strategy, 5, [{a, permanent, counter()}, {b, permanent, Sibling}]),
        A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
        try queued_restart(Sup, A, B) after lawspec_beam_actors:stop(Sup) end
    end, [one_for_all, rest_for_one]).

escalated_restart_preserves_sibling_mailbox_order_test() ->
    Test = self(),
    Sibling = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> Test ! {restart_checkpoint, S}, 0 end),
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 0, 10000000,
        [{a, permanent, counter()}, {b, permanent, Sibling}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner),
    A = lawspec_beam_actors:child(Inner, a), B = lawspec_beam_actors:child(Inner, b),
    try queued_restart(Sup, A, B) after lawspec_beam_actors:stop(Sup) end.

queued_restart_failure_is_supervised_test() ->
    Attempts = atomics:new(1, []),
    Sibling = lawspec_beam_actors:actor(fun() -> 0 end, fun(_) ->
        case atomics:add_get(Attempts, 1, 1) of 1 -> error(restart_broken); _ -> 0 end
    end),
    Sup = tree(rest_for_one, 5, [{a, permanent, counter()}, {b, permanent, Sibling}]),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    try
        lawspec_beam_actors:monitor(B, self()),
        lawspec_beam_actors:crash(A),
        ?assertEqual(0, lawspec_beam_actors:state(B)),
        receive {lawspec_actor_event, B, {crashed, {error, restart_broken, _}}} -> ok
            after 1000 -> error(no_restart_failure) end,
        ?assertEqual(2, lawspec_beam_actors:restart_count(Sup)),
        ?assertEqual(2, atomics:get(Attempts, 1))
    after lawspec_beam_actors:stop(Sup) end.

overlapping_supervisor_restarts_keep_both_logical_restarts_test() ->
    Test = self(),
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> Test ! {restored, S}, S + 1 end),
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, Spec}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    OldWorker = lawspec_beam_actors:worker_pid(A),
    try
        lawspec_beam_actors:tell(A, fun(S) -> Test ! entered, receive continue -> {ok, S + 1} end end),
        receive entered -> ok after 1000 -> error(not_entered) end,
        lawspec_beam_actors:tell(A, fun(S) -> {ok, S + 3} end),
        exit(lawspec_beam_actors:worker_pid(Inner), kill),
        wait(fun() -> maps:get(claim, actor_node(A)) =/= none end),
        {FirstReplacement, _} = maps:get(claim, actor_node(A)),
        exit(lawspec_beam_actors:worker_pid(Inner), kill),
        wait(fun() -> case maps:get(claim, actor_node(A)) of
            {Pid, _} -> Pid =/= FirstReplacement;
            none -> false
        end end),
        OldWorker ! continue,
        ?assertEqual(6, lawspec_beam_actors:state(A)),
        States = [receive {restored, S} -> S after 1000 -> error(no_restart) end || _ <- [1, 2]],
        ?assertEqual([4, 5], States),
        ?assertEqual(2, lawspec_beam_actors:restart_count(Sup))
    after OldWorker ! continue, lawspec_beam_actors:stop(Sup) end.

queued_restart(Sup, Failed, Sibling) ->
    Test = self(), Worker = lawspec_beam_actors:worker_pid(Sibling),
    lawspec_beam_actors:tell(Sibling, fun(S) ->
        Test ! entered, receive continue -> {ok, S + 1} end
    end),
    receive entered -> ok after 1000 -> error(not_entered) end,
    lawspec_beam_actors:tell(Sibling, fun(S) -> Test ! {queued_checkpoint, S}, {ok, S + 3} end),
    spawn(fun() -> lawspec_beam_actors:crash(Failed), Test ! crashed end),
    try
        wait(fun() -> maps:get(restarting, actor_node(Sibling)) end),
        lawspec_beam_actors:tell(Sibling, fun(S) -> {ok, S + 10} end),
        Worker ! continue,
        receive crashed -> ok after 1000 -> error(crash_hung) end,
        ?assertEqual(10, lawspec_beam_actors:state(Sibling)),
        receive {queued_checkpoint, Before} -> ?assertEqual(1, Before) after 1000 -> error(message_lost) end,
        receive {restart_checkpoint, BeforeRestart} -> ?assertEqual(4, BeforeRestart)
            after 1000 -> error(no_restart) end,
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup)),
        ?assertNotEqual(Worker, lawspec_beam_actors:worker_pid(Sibling))
    after Worker ! continue end.

otp_lifetimes_test() ->
    Sup = tree(one_for_one, 5, [{p, permanent, counter()}, {t, transient, counter()}, {x, temporary, counter()}]),
    P = lawspec_beam_actors:child(Sup, p), T = lawspec_beam_actors:child(Sup, t), X = lawspec_beam_actors:child(Sup, x),
    try
        bump(P), lawspec_beam_actors:stop(P),
        ?assertEqual(0, lawspec_beam_actors:state(P)),
        bump(T), lawspec_beam_actors:crash(T),
        ?assertEqual(0, lawspec_beam_actors:state(T)),
        lawspec_beam_actors:stop(T),
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(T)),
        lawspec_beam_actors:crash(X),
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(X)),
        ?assertEqual([{p, P}], lawspec_beam_actors:children(Sup))
    after lawspec_beam_actors:stop(Sup) end.

restart_limit_stops_root_and_notifies_once_test() ->
    Sup = tree(one_for_one, 2, [{a, permanent, counter()}, {b, permanent, counter()}]),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    lawspec_beam_actors:monitor(Sup, self()),
    lawspec_beam_actors:monitor(B, self()),
    Root = lawspec_beam_actors:worker_pid(Sup),
    [lawspec_beam_actors:crash(A) || _ <- lists:seq(1, 3)],
    ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(B)),
    receive {lawspec_supervisor_event, Sup, {crashed, _}} -> ok after 1000 -> error(no_limit_event) end,
    receive {lawspec_actor_event, B, {stopped, none}} -> ok after 1000 -> error(no_child_stop) end,
    await_dead(Root),
    receive {lawspec_supervisor_event, Sup, _} -> error(duplicate_event) after 0 -> ok end.

nested_limit_escalates_through_real_otp_supervisor_test() ->
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 1, 10000000,
        [{a, permanent, counter()}, {b, permanent, counter()}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}, {c, permanent, counter()}]),
    Inner = lawspec_beam_actors:child(Sup, inner),
    A = lawspec_beam_actors:child(Inner, a), B = lawspec_beam_actors:child(Inner, b), C = lawspec_beam_actors:child(Sup, c),
    Old = lawspec_beam_actors:worker_pid(Inner),
    try
        bump(B), bump(C),
        lawspec_beam_actors:crash(A), lawspec_beam_actors:crash(A),
        ?assertEqual([0, 0, 1], [lawspec_beam_actors:state(X) || X <- [A, B, C]]),
        ?assertNotEqual(Old, lawspec_beam_actors:worker_pid(Inner)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup)),
        ?assertEqual(0, lawspec_beam_actors:restart_count(Inner))
    after lawspec_beam_actors:stop(Sup) end.

linked_crash_crosses_cycles_once_test() ->
    Sup = tree(one_for_one, 10, [{a, permanent, counter()}, {b, permanent, counter()}, {c, permanent, counter()}]),
    [A, B, C] = [lawspec_beam_actors:child(Sup, Name) || Name <- [a, b, c]],
    try
        lawspec_beam_actors:link(A, B), lawspec_beam_actors:link(B, C), lawspec_beam_actors:link(C, A),
        [bump(X) || X <- [A, B, C]],
        [lawspec_beam_actors:monitor(X, self()) || X <- [A, B, C]],
        lawspec_beam_actors:crash(A),
        [receive {lawspec_actor_event, X, {crashed, _}} -> ok after 1000 -> error(no_link_event) end || X <- [A, B, C]],
        ?assertEqual([0, 0, 0], [lawspec_beam_actors:state(X) || X <- [A, B, C]]),
        ?assertEqual(3, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

subsecond_restart_window_is_not_rounded_to_seconds_test() ->
    Spec = lawspec_beam_actors:supervisor(one_for_one, 1, 10000, [{a, permanent, counter()}]),
    Sup = lawspec_beam_actors:start_supervisor(Spec), A = lawspec_beam_actors:child(Sup, a),
    try
        lawspec_beam_actors:crash(A),
        timer:sleep(20),
        lawspec_beam_actors:crash(A),
        ?assertEqual(0, lawspec_beam_actors:state(A)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

external_worker_kill_recovers_committed_state_test() ->
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> S end),
    Sup = tree(one_for_one, 5, [{a, permanent, Spec}]), A = lawspec_beam_actors:child(Sup, a),
    try
        bump(A), lawspec_beam_actors:monitor(A, self()),
        Worker = lawspec_beam_actors:worker_pid(A), exit(Worker, kill),
        receive {lawspec_actor_event, A, {crashed, _}} -> ok after 1000 -> error(no_kill_event) end,
        ?assertEqual(1, lawspec_beam_actors:state(A)),
        ?assertNotEqual(Worker, lawspec_beam_actors:worker_pid(A)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

stable_service_death_closes_otp_tree_test() ->
    Sup = tree(one_for_one, 5, [{a, permanent, counter()}, {b, permanent, counter()}]),
    {lawspec_supervisor, Tree, _} = Sup,
    Pids = [lawspec_beam_actors:worker_pid(H) || H <- [Sup | [A || {_, A} <- lawspec_beam_actors:children(Sup)]]],
    exit(Tree, kill),
    [await_dead(Pid) || Pid <- Pids].

startup_failure_is_reported_test() ->
    ?assertMatch({lawspec, {actor_start_failed, _}}, failure(fun() ->
        lawspec_beam_actors:start(fun() -> error(start_broken) end)
    end)).

failed_restart_exhausts_budget_and_stops_test() ->
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(_) -> error(restart_broken) end),
    Sup = tree(one_for_one, 2, [{a, permanent, Spec}]), A = lawspec_beam_actors:child(Sup, a),
    Root = lawspec_beam_actors:worker_pid(Sup),
    lawspec_beam_actors:crash(A),
    await_dead(Root),
    ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(A)).

replacement_waits_for_old_worker_checkpoint_after_supervisor_kill_test() ->
    Test = self(),
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> Test ! {restored, S}, S end),
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, Spec}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    OldWorker = lawspec_beam_actors:worker_pid(A), OldSup = lawspec_beam_actors:worker_pid(Inner),
    try
        lawspec_beam_actors:tell(A, fun(S) ->
            Test ! entered, receive continue -> {ok, S + 1} end
        end),
        receive entered -> ok after 1000 -> error(not_entered) end,
        lawspec_beam_actors:tell(A, fun(S) -> {ok, S + 1} end),
        exit(OldSup, kill),
        wait(fun() -> maps:get(claim, actor_node(A)) =/= none end),
        ?assert(is_process_alive(OldWorker)),
        receive {restored, _} -> error(restarted_before_old_commit) after 0 -> ok end,
        OldWorker ! continue,
        ?assertEqual(2, lawspec_beam_actors:state(A)),
        receive {restored, 2} -> ok after 1000 -> error(checkpoint_lost) end,
        ?assertNotEqual(OldWorker, lawspec_beam_actors:worker_pid(A))
    after OldWorker ! continue, lawspec_beam_actors:stop(Sup) end.

normal_stop_of_permanent_nested_supervisor_restarts_in_place_test() ->
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, counter()}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    OldSup = lawspec_beam_actors:worker_pid(Inner),
    try
        bump(A), lawspec_beam_actors:stop(Inner),
        ?assertEqual(0, lawspec_beam_actors:state(A)),
        ?assertNotEqual(OldSup, lawspec_beam_actors:worker_pid(Inner)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

root_stop_during_restart_drains_the_queue_test() ->
    Test = self(),
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) ->
        Test ! {restarting, self()}, receive continue -> S end
    end),
    Sup = tree(one_for_one, 5, [{a, permanent, Spec}]), A = lawspec_beam_actors:child(Sup, a),
    spawn(fun() -> lawspec_beam_actors:crash(A), Test ! crashed end),
    Worker = receive {restarting, Pid} -> Pid after 1000 -> error(no_restart) end,
    lawspec_beam_actors:tell(A, fun(S) -> Test ! {drained, S + 1}, {ok, S + 1} end),
    spawn(fun() -> lawspec_beam_actors:stop(Sup), Test ! stopped end),
    wait(fun() -> maps:get(closing, actor_node(A)) end),
    Worker ! continue,
    receive crashed -> ok after 1000 -> error(crash_hung) end,
    receive {drained, 1} -> ok after 1000 -> error(queue_lost) end,
    receive stopped -> ok after 1000 -> error(stop_hung) end,
    await_dead(Worker).

temporary_sibling_is_not_resurrected_by_otp_group_restart_test() ->
    Sup = tree(one_for_all, 5, [{a, permanent, counter()}, {b, temporary, counter()}]),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    try
        lawspec_beam_actors:crash(A),
        ?assertEqual(0, lawspec_beam_actors:state(A)),
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(B)),
        ?assertEqual([{a, A}], lawspec_beam_actors:children(Sup))
    after lawspec_beam_actors:stop(Sup) end.

normally_stopped_transient_is_not_resurrected_by_sibling_restart_test() ->
    Sup = tree(one_for_all, 5, [{a, permanent, counter()}, {b, transient, counter()}]),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    try
        lawspec_beam_actors:stop(B),
        lawspec_beam_actors:crash(A),
        ?assertEqual(0, lawspec_beam_actors:state(A)),
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(B))
    after lawspec_beam_actors:stop(Sup) end.

unstarted_delivery_is_requeued_after_worker_kill_test() ->
    Sup = tree(one_for_one, 5, [{a, permanent, counter()}]), A = lawspec_beam_actors:child(Sup, a),
    Worker = lawspec_beam_actors:worker_pid(A),
    true = erlang:suspend_process(Worker),
    try
        lawspec_beam_actors:tell(A, fun(S) -> {ok, S + 1} end),
        ?assertMatch(#{begun := false}, maps:get(active, actor_node(A))),
        exit(Worker, kill),
        ?assertEqual(1, lawspec_beam_actors:state(A))
    after lawspec_beam_actors:stop(Sup) end.

interrupted_running_handler_is_not_replayed_test() ->
    Test = self(),
    Sup = tree(one_for_one, 5, [{a, permanent, counter()}]), A = lawspec_beam_actors:child(Sup, a),
    Worker = lawspec_beam_actors:worker_pid(A),
    try
        spawn(fun() -> Test ! {failed, failure(fun() -> lawspec_beam_actors:call(A, fun(S) ->
            Test ! entered, receive continue -> {S + 1, S + 1} end
        end) end)} end),
        receive entered -> ok after 1000 -> error(not_entered) end,
        lawspec_beam_actors:tell(A, fun(S) -> {ok, S + 2} end),
        exit(Worker, kill),
        receive {failed, {lawspec, {actor_crashed, {exit, killed, []}}}} -> ok
            after 1000 -> error(no_failure) end,
        ?assertEqual(2, lawspec_beam_actors:state(A)),
        receive entered -> error(replayed_side_effect) after 0 -> ok end
    after lawspec_beam_actors:stop(Sup) end.

accepted_messages_survive_sender_exit_test() ->
    Actor = lawspec_beam_actors:start(fun() -> 0 end),
    Test = self(), Worker = lawspec_beam_actors:worker_pid(Actor),
    lawspec_beam_actors:tell(Actor, fun(S) ->
        Test ! entered, receive continue -> {ok, S} end
    end),
    receive entered -> ok after 1000 -> error(not_entered) end,
    Sender = spawn(fun() -> lawspec_beam_actors:call(Actor, fun(S) -> {ok, S + 1} end) end),
    wait(fun() -> not queue:is_empty(maps:get(waiting, actor_node(Actor))) end),
    exit(Sender, kill),
    Worker ! continue,
    try ?assertEqual(1, lawspec_beam_actors:state(Actor)) after lawspec_beam_actors:stop(Actor) end.

caller_cancellation_scope_does_not_own_persistent_actor_test() ->
    Actor = lawspec_beam_tasks:with_scope(fun(_) ->
        A = lawspec_beam_actors:start(fun() -> 0 end),
        ?assertEqual(1, bump(A)), A
    end),
    try ?assertEqual(2, bump(Actor)) after lawspec_beam_actors:stop(Actor) end.

start_and_root_stop_follow_declared_order_test() ->
    Test = self(),
    Spec = fun(Name) -> lawspec_beam_actors:actor(fun() -> Test ! {started, Name}, 0 end, fun(_) -> 0 end) end,
    Sup = tree(one_for_one, 5, [{a, permanent, Spec(a)}, {b, permanent, Spec(b)}, {c, permanent, Spec(c)}]),
    Started = [receive {started, N} -> N after 1000 -> error(not_started) end || _ <- [a, b, c]],
    ?assertEqual([a, b, c], Started),
    Children = lawspec_beam_actors:children(Sup),
    {lawspec_supervisor, Tree, _} = Sup,
    [lawspec_beam_actors:monitor(A, Test) || {_, A} <- Children],
    lawspec_beam_actors:stop(Sup),
    Stopped = [receive {lawspec_actor_event, Actor = {lawspec_actor, Tree, _}, {stopped, none}} -> Actor
        after 1000 -> error(no_stop_event) end || _ <- Children],
    ?assertEqual(lists:reverse([A || {_, A} <- Children]), Stopped).

links_cross_independent_trees_test() ->
    A = lawspec_beam_actors:start(fun() -> 0 end), B = lawspec_beam_actors:start(fun() -> 0 end),
    lawspec_beam_actors:monitor(B, self()), lawspec_beam_actors:link(A, B),
    lawspec_beam_actors:crash(A),
    receive {lawspec_actor_event, B, {crashed, _}} -> ok after 1000 -> error(no_link_crash) end,
    ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(B)).

external_kill_crosses_a_link_cycle_once_test() ->
    Sup = tree(one_for_one, 10, [{a, permanent, counter()}, {b, permanent, counter()}, {c, permanent, counter()}]),
    [A, B, C] = [lawspec_beam_actors:child(Sup, Name) || Name <- [a, b, c]],
    try
        lawspec_beam_actors:link(A, B), lawspec_beam_actors:link(B, C), lawspec_beam_actors:link(C, A),
        [lawspec_beam_actors:monitor(X, self()) || X <- [A, B, C]],
        exit(lawspec_beam_actors:worker_pid(A), kill),
        [receive {lawspec_actor_event, X, {crashed, _}} -> ok after 1000 -> error(no_link_event) end || X <- [A, B, C]],
        ?assertEqual([0, 0, 0], [lawspec_beam_actors:state(X) || X <- [A, B, C]]),
        ?assertEqual(3, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

superseded_replacement_does_not_leak_an_initializing_worker_test() ->
    Test = self(),
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> S end),
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, Spec}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    OldWorker = lawspec_beam_actors:worker_pid(A),
    try
        lawspec_beam_actors:tell(A, fun(S) -> Test ! entered, receive continue -> {ok, S + 1} end end),
        receive entered -> ok after 1000 -> error(not_entered) end,
        exit(lawspec_beam_actors:worker_pid(Inner), kill),
        wait(fun() -> maps:get(claim, actor_node(A)) =/= none end),
        {FirstReplacement, _} = maps:get(claim, actor_node(A)),
        exit(lawspec_beam_actors:worker_pid(Inner), kill),
        wait(fun() -> case maps:get(claim, actor_node(A)) of
            {Pid, _} -> Pid =/= FirstReplacement;
            none -> false
        end end),
        await_dead(FirstReplacement),
        OldWorker ! continue,
        ?assertEqual(1, lawspec_beam_actors:state(A)),
        ?assertEqual(2, lawspec_beam_actors:restart_count(Sup))
    after OldWorker ! continue, lawspec_beam_actors:stop(Sup) end.

self_call_and_parent_stop_report_errors_instead_of_deadlocking_test() ->
    Sup = tree(one_for_one, 5, [{a, permanent, counter()}]), A = lawspec_beam_actors:child(Sup, a),
    try
        ?assertEqual({lawspec, actor_self_call}, lawspec_beam_actors:call(A, fun(S) ->
            {failure(fun() -> lawspec_beam_actors:state(A) end), S}
        end)),
        ?assertEqual({lawspec, actor_self_stop}, lawspec_beam_actors:call(A, fun(S) ->
            {failure(fun() -> lawspec_beam_actors:stop(Sup) end), S}
        end))
    after lawspec_beam_actors:stop(Sup) end.

zero_restart_budget_escalates_immediately_test() ->
    Sup = tree(one_for_one, 0, [{a, permanent, counter()}]), A = lawspec_beam_actors:child(Sup, a),
    Root = lawspec_beam_actors:worker_pid(Sup),
    lawspec_beam_actors:crash(A), await_dead(Root),
    ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(A)).

normal_stop_of_transient_nested_supervisor_removes_subtree_test() ->
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, counter()}]),
    Sup = tree(one_for_all, 5, [{inner, transient, InnerSpec}, {b, permanent, counter()}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    B = lawspec_beam_actors:child(Sup, b),
    try
        lawspec_beam_actors:stop(Inner),
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(A)),
        lawspec_beam_actors:crash(B),
        ?assertEqual(0, lawspec_beam_actors:state(B)),
        ?assertEqual([{b, B}], lawspec_beam_actors:children(Sup))
    after lawspec_beam_actors:stop(Sup) end.

empty_supervisor_starts_and_stops_test() ->
    Sup = tree(one_for_one, 5, []), Root = lawspec_beam_actors:worker_pid(Sup),
    ?assertEqual([], supervisor:which_children(Root)),
    ?assertEqual([], lawspec_beam_actors:children(Sup)),
    lawspec_beam_actors:stop(Sup), await_dead(Root).

otp_normal_exit_respects_transient_lifetime_test() ->
    Sup = tree(one_for_one, 5, [{a, transient, counter()}, {b, permanent, counter()}]),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    try
        lawspec_beam_actors:monitor(A, self()),
        gen_server:stop(lawspec_beam_actors:worker_pid(A), normal, infinity),
        receive {lawspec_actor_event, A, {stopped, none}} -> ok after 1000 -> error(no_stop_event) end,
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(A)),
        ?assertEqual(1, bump(B)),
        ?assertEqual(0, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

supervisor_kill_restarts_its_temporary_children_as_part_of_new_instance_test() ->
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, temporary, counter()}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    Old = lawspec_beam_actors:worker_pid(Inner),
    try
        bump(A), lawspec_beam_actors:monitor(Inner, self()),
        exit(Old, kill),
        receive {lawspec_supervisor_event, Inner, {crashed, {exit, killed, []}}} -> ok
            after 1000 -> error(no_supervisor_event) end,
        ?assertEqual(0, lawspec_beam_actors:state(A)),
        ?assertEqual(0, lawspec_beam_actors:restart_count(Inner)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

root_kill_reports_actual_cause_test() ->
    Sup = tree(one_for_one, 5, [{a, permanent, counter()}]),
    lawspec_beam_actors:monitor(Sup, self()),
    exit(lawspec_beam_actors:worker_pid(Sup), kill),
    receive {lawspec_supervisor_event, Sup, {crashed, {exit, killed, []}}} -> ok
        after 1000 -> error(wrong_root_cause) end.

retiring_initialization_cannot_release_a_new_generations_mailbox_test() ->
    Test = self(), Attempts = atomics:new(1, []),
    Spec = lawspec_beam_actors:actor(fun() -> 10 end, fun(S) ->
        case atomics:add_get(Attempts, 1, 1) of
            1 -> Test ! {restoring, self()}, receive continue -> S + 1 end;
            _ -> S + 1
        end
    end),
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, Spec}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    spawn(fun() -> lawspec_beam_actors:crash(A), Test ! restored end),
    Old = receive {restoring, Pid} -> Pid after 1000 -> error(no_restore) end,
    try
        exit(lawspec_beam_actors:worker_pid(Inner), kill),
        wait(fun() -> maps:get(claim, actor_node(A)) =/= none end),
        lawspec_beam_actors:tell(A, fun(S) -> Test ! {handled_by, self()}, {ok, S + 1} end),
        Old ! continue,
        receive restored -> ok after 1000 -> error(restore_hung) end,
        ?assertEqual(13, lawspec_beam_actors:state(A)),
        receive {handled_by, Handler} -> ?assertNotEqual(Old, Handler) after 1000 -> error(message_lost) end,
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup)),
        ?assertEqual(0, lawspec_beam_actors:restart_count(Inner))
    after Old ! continue, lawspec_beam_actors:stop(Sup) end.

pending_call_reports_actor_stopped_when_mailbox_service_dies_test() ->
    Actor = lawspec_beam_actors:start(fun() -> 0 end), {lawspec_actor, Tree, _} = Actor,
    Worker = lawspec_beam_actors:worker_pid(Actor), Test = self(),
    true = erlang:suspend_process(Worker),
    spawn(fun() -> Test ! {outcome, failure(fun() -> bump(Actor) end)} end),
    wait(fun() -> maps:get(active, actor_node(Actor)) =/= none end),
    exit(Tree, kill), true = erlang:resume_process(Worker),
    receive {outcome, {lawspec, actor_stopped}} -> ok after 1000 -> error(wrong_pending_failure) end,
    await_dead(Worker).

startup_owner_death_cancels_a_blocked_initializer_test() ->
    Test = self(),
    Owner = spawn(fun() -> lawspec_beam_actors:start(fun() ->
        [Root, Tree | _] = get('$ancestors'),
        [Scope] = get({lawspec_beam_tasks, scopes}),
        Test ! {initializing, self(), Root, Tree, Scope},
        receive forever -> 0 end
    end) end),
    {Worker, Root, Tree, Scope} = receive {initializing, W, R, T, S} -> {W, R, T, S}
        after 1000 -> error(no_initializer) end,
    exit(Owner, kill),
    [await_dead(Pid) || Pid <- [Worker, Root, Tree, Scope]].

normal_shutdown_leaves_no_actor_guard_test() ->
    A = lawspec_beam_actors:start(fun() -> 0 end), Worker = lawspec_beam_actors:worker_pid(A),
    Guard = maps:get(guard, sys:get_state(Worker)),
    ?assert(is_process_alive(Guard)),
    lawspec_beam_actors:stop(A), await_dead(Guard).

repeated_failed_start_releases_mailbox_service_test() ->
    Test = self(),
    lists:foreach(fun(_) ->
        ?assertMatch({lawspec, {actor_start_failed, _}}, failure(fun() ->
            lawspec_beam_actors:start(fun() ->
                [_, Tree | _] = get('$ancestors'), Test ! {failed_tree, Tree}, error(start_broken)
            end)
        end)),
        receive {failed_tree, Tree} -> await_dead(Tree) after 1000 -> error(no_tree) end
    end, lists:seq(1, 20)).

native_supervisor_stop_restarts_children_without_losing_transient_or_temporary_handles_test() ->
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000,
        [{a, transient, counter()}, {b, temporary, counter()}, {c, permanent, counter()}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner),
    Actors = [lawspec_beam_actors:child(Inner, N) || N <- [a, b, c]],
    try
        [bump(A) || A <- Actors],
        [lawspec_beam_actors:monitor(A, self()) || A <- Actors],
        gen_server:stop(lawspec_beam_actors:worker_pid(Inner), normal, infinity),
        ?assertEqual([0, 0, 0], [lawspec_beam_actors:state(A) || A <- Actors]),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup)),
        ?assertEqual(0, lawspec_beam_actors:restart_count(Inner)),
        [receive {lawspec_actor_event, A, _} -> error(spurious_child_stop) after 0 -> ok end || A <- Actors]
    after lawspec_beam_actors:stop(Sup) end.

external_kill_charges_one_restart_for_each_otp_strategy_test() ->
    lists:foreach(fun({Strategy, Expected}) ->
        Sup = tree(Strategy, 5, [{a, permanent, counter()}, {b, permanent, counter()}, {c, permanent, counter()}]),
        [A, B, C] = [lawspec_beam_actors:child(Sup, Name) || Name <- [a, b, c]],
        try
            [bump(X) || X <- [A, B, C]],
            lawspec_beam_actors:monitor(B, self()),
            exit(lawspec_beam_actors:worker_pid(B), kill),
            receive {lawspec_actor_event, B, {crashed, _}} -> ok after 1000 -> error(no_crash) end,
            ?assertEqual(Expected, [lawspec_beam_actors:state(X) || X <- [A, B, C]]),
            ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
        after lawspec_beam_actors:stop(Sup) end
    end, [{one_for_one, [1, 0, 1]}, {one_for_all, [0, 0, 0]}, {rest_for_one, [1, 0, 0]}]).

external_kill_cannot_run_sibling_initializers_past_the_budget_test() ->
    Restarts = atomics:new(1, []),
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(_) -> atomics:add(Restarts, 1, 1), 0 end),
    Sup = tree(one_for_all, 0, [{a, permanent, Spec}, {b, permanent, Spec}, {c, permanent, Spec}]),
    B = lawspec_beam_actors:child(Sup, b), Root = lawspec_beam_actors:worker_pid(Sup),
    exit(lawspec_beam_actors:worker_pid(B), kill),
    await_dead(Root),
    ?assertEqual(0, atomics:get(Restarts, 1)).

native_shutdown_exit_obeys_child_lifetime_test() ->
    Sup = tree(one_for_one, 5, [{a, permanent, counter()}, {b, transient, counter()}]),
    A = lawspec_beam_actors:child(Sup, a), B = lawspec_beam_actors:child(Sup, b),
    try
        bump(A), lawspec_beam_actors:monitor(B, self()),
        gen_server:stop(lawspec_beam_actors:worker_pid(A), shutdown, infinity),
        ?assertEqual(0, lawspec_beam_actors:state(A)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup)),
        gen_server:stop(lawspec_beam_actors:worker_pid(B), shutdown, infinity),
        receive {lawspec_actor_event, B, {stopped, none}} -> ok after 1000 -> error(no_stop) end,
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(B)),
        ?assertEqual(1, lawspec_beam_actors:restart_count(Sup))
    after lawspec_beam_actors:stop(Sup) end.

native_stop_of_standalone_actor_releases_its_mailbox_and_supervisor_test() ->
    lists:foreach(fun(Reason) ->
        A = lawspec_beam_actors:start(fun() -> 0 end), {lawspec_actor, Tree, _} = A,
        Worker = lawspec_beam_actors:worker_pid(A), Root = maps:get(root, sys:get_state(Tree)),
        lawspec_beam_actors:monitor(A, self()),
        case Reason of kill -> exit(Worker, kill); _ -> gen_server:stop(Worker, Reason, infinity) end,
        receive {lawspec_actor_event, A, _} -> ok after 1000 -> error(no_event) end,
        [await_dead(Pid) || Pid <- [Worker, Root, Tree]],
        ?assertError({lawspec, actor_stopped}, lawspec_beam_actors:state(A))
    end, [kill, normal, shutdown]).

stopping_a_permanent_supervisor_waits_for_its_replacement_children_test() ->
    Test = self(),
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) ->
        Test ! {restarting, self()}, receive continue -> S + 1 end
    end),
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, Spec}]),
    Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
    Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
    {lawspec_supervisor, Tree, Id} = Inner,
    spawn(fun() -> lawspec_beam_actors:stop(Inner), Test ! supervisor_stopped end),
    Worker = receive {restarting, Pid} -> Pid after 1000 -> error(no_restart) end,
    try
        ?assert(maps:is_key(Id, maps:get(stops, sys:get_state(Tree)))),
        Worker ! continue,
        receive supervisor_stopped -> ok after 1000 -> error(stop_hung) end,
        ?assertEqual(1, lawspec_beam_actors:state(A))
    after Worker ! continue, lawspec_beam_actors:stop(Sup) end.

mailbox_death_during_init_cleans_up_native_async_work_test_() ->
    {timeout, 10, fun() ->
        Test = self(),
        Owner = spawn(fun() -> lawspec_beam_actors:start(fun() ->
            [Root, Tree | _] = get('$ancestors'), Worker = self(),
            lawspec_beam_runtime:async_call(fun() ->
                Test ! {initializing, Worker, Root, Tree, self()},
                receive forever -> 0 end
            end)
        end) end),
        {Worker, Root, Tree, Body} = receive {initializing, W, R, T, B} -> {W, R, T, B}
            after 1000 -> error(no_initializer) end,
        RootMonitor = erlang:monitor(process, Root), exit(Tree, kill),
        receive {'DOWN', RootMonitor, process, Root, _} -> ok after 7000 -> error(root_leaked) end,
        [await_dead(Pid) || Pid <- [Owner, Worker, Body]]
    end}.

killed_supervisor_cannot_leave_a_blocked_actor_or_its_async_work_test_() ->
    {timeout, 10, fun() ->
        Test = self(), Shared = ets:new(actors_shutdown, [public, set]),
        Spec = lawspec_beam_actors:actor(fun() -> 10 end, fun(S) ->
            [{body, OldBody}] = ets:lookup(Shared, body),
            ?assertNot(is_process_alive(OldBody)), S + 1
        end),
        InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 5, 10000000, [{a, permanent, Spec}]),
        Sup = tree(one_for_one, 5, [{inner, permanent, InnerSpec}]),
        Inner = lawspec_beam_actors:child(Sup, inner), A = lawspec_beam_actors:child(Inner, a),
        try
            spawn(fun() -> Test ! {failed, failure(fun() -> lawspec_beam_actors:call(A, fun(S) ->
                lawspec_beam_runtime:async_call(fun() ->
                    true = ets:insert(Shared, {body, self()}), Test ! blocked,
                    receive forever -> {ok, S} end
                end)
            end) end)} end),
            receive blocked -> ok after 1000 -> error(no_body) end,
            lawspec_beam_actors:tell(A, fun(S) -> {ok, S + 10} end),
            exit(lawspec_beam_actors:worker_pid(Inner), kill),
            receive {failed, {lawspec, {actor_crashed, {exit, killed, []}}}} -> ok
                after 7000 -> error(blocked_actor_leaked) end,
            ?assertEqual(21, lawspec_beam_actors:state(A))
        after lawspec_beam_actors:stop(Sup), ets:delete(Shared) end
    end}.

service_death_bounds_shutdown_of_a_blocked_native_handler_test_() ->
    {timeout, 10, fun() ->
        Test = self(), Sup = tree(one_for_one, 5, [{a, permanent, counter()}]),
        A = lawspec_beam_actors:child(Sup, a), {lawspec_supervisor, Tree, _} = Sup,
        Worker = lawspec_beam_actors:worker_pid(A), Root = lawspec_beam_actors:worker_pid(Sup),
        lawspec_beam_actors:tell(A, fun(S) ->
            lawspec_beam_runtime:async_call(fun() ->
                Test ! {blocked, self()}, receive continue -> {ok, S} end
            end)
        end),
        Body = receive {blocked, Pid} -> Pid after 1000 -> error(no_body) end,
        Monitor = erlang:monitor(process, Root), exit(Tree, kill),
        receive {'DOWN', Monitor, process, Root, _} -> ok after 7000 -> error(root_leaked) end,
        await_dead(Worker), await_dead(Body)
    end}.

counter() -> lawspec_beam_actors:actor(fun() -> 0 end, fun(_) -> 0 end).
tree(Strategy, Restarts, Children) -> lawspec_beam_actors:start_supervisor(
    lawspec_beam_actors:supervisor(Strategy, Restarts, 10000000, Children)).
bump(Actor) -> lawspec_beam_actors:call(Actor, fun(S) -> {S + 1, S + 1} end).
actor_node({_, Tree, Id}) -> maps:get(Id, maps:get(nodes, sys:get_state(Tree))).
failure(Body) -> try Body(), no_failure catch error:Reason -> Reason end.
await_dead(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive {'DOWN', Monitor, process, Pid, _} -> ok after 1000 -> error({leaked, Pid}) end.
wait(Condition) -> wait(Condition, 1000).
wait(_, 0) -> error(condition_timeout);
wait(Condition, Remaining) -> case Condition() of
    true -> ok;
    false -> timer:sleep(1), wait(Condition, Remaining - 1)
end.
