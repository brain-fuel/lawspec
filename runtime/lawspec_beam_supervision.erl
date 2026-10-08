%% @doc Generated supervision evidence exercises actual OTP processes,
%% restart strategies, lifetimes, escalation, links and stable mailboxes.
%% Each check owns its tree; monitor messages stay in the checking worker.
%% ref:DEC-actors-otp-supervision ref:erlang-otp-supervisors
-module(lawspec_beam_supervision).
-export([check/0]).

check() -> lawspec_beam_runtime:async_call(fun checks/0).
checks() ->
    lawspec_beam_actors:with_spec(counter(), fun(A) ->
        expect(initial_increment, 1, bump(A)), fail_call(A), stopped(A)
    end),
    lists:foreach(fun({Strategy, Expected}) ->
        tree(Strategy, 5, counters([a, b, c]), fun(Sup) ->
            As = children(Sup, [a, b, c]),
            Before = [lawspec_beam_actors:worker_pid(A) || A <- As],
            lists:foreach(fun(A) ->
                {status, _, {module, gen_server}, _} = sys:get_status(lawspec_beam_actors:worker_pid(A)), bump(A)
            end, As),
            expect(real_otp_supervisor, 3, length(supervisor:which_children(lawspec_beam_actors:worker_pid(Sup)))),
            fail_call(lists:nth(2, As)),
            expect(Strategy, Expected, states(As)),
            After = [lawspec_beam_actors:worker_pid(A) || A <- As],
            expect({Strategy, replaced_workers}, [V =:= 0 || V <- Expected],
                [P =/= Q || {P, Q} <- lists:zip(Before, After)])
        end)
    end, [{one_for_one, [1, 0, 1]}, {one_for_all, [0, 0, 0]}, {rest_for_one, [1, 0, 0]}]),
    lifetimes(), limits(), escalation(), links(), checkpoint_and_mailbox(),
    lists:foreach(fun queued_sibling_restart/1, [one_for_all, rest_for_one]), ok.

counter() -> lawspec_beam_actors:actor(fun() -> 0 end, fun(_) -> 0 end).
counters(Names) -> [{N, permanent, counter()} || N <- Names].
tree(Strategy, Limit, Children, Body) ->
    lawspec_beam_actors:with_spec(lawspec_beam_actors:supervisor(Strategy, Limit, 10000000, Children), Body).
children(Sup, Names) -> [lawspec_beam_actors:child(Sup, N) || N <- Names].
states(As) -> [lawspec_beam_actors:state(A) || A <- As].
bump(A) -> lawspec_beam_actors:call(A, fun(S) -> {S + 1, S + 1} end).
fail_call(A) ->
    try lawspec_beam_actors:call(A, fun(_) -> error(supervision_probe) end) of
        Value -> failure(failing_handler, actor_crashed, Value)
    catch error:{lawspec, {actor_crashed, {error, supervision_probe, _}}} -> ok end.
stopped(A) ->
    try lawspec_beam_actors:state(A) of Value -> failure(stopped_actor, actor_stopped, Value)
    catch error:{lawspec, actor_stopped} -> ok end.
expect(_, Wanted, Wanted) -> ok;
expect(Label, Wanted, Actual) -> failure(Label, Wanted, Actual).
failure(Label, Wanted, Actual) -> error({lawspec, {supervision_failed, Label, #{expected => Wanted, actual => Actual}}}).
crashed(Handle) ->
    case lawspec_beam_actors:receive_event(Handle, 2000) of
        {ok, {crashed, _}} -> ok;
        Other -> failure(crash_monitor, crashed, Other)
    end.

lifetimes() ->
    tree(one_for_one, 5, [{p, permanent, counter()}, {t, transient, counter()}, {x, temporary, counter()}], fun(Sup) ->
        [P, T, X] = children(Sup, [p, t, x]),
        bump(P), lawspec_beam_actors:stop(P), expect(permanent_normal_stop, 0, lawspec_beam_actors:state(P)),
        bump(T), fail_call(T), expect(transient_crash, 0, lawspec_beam_actors:state(T)),
        lawspec_beam_actors:stop(T), stopped(T),
        fail_call(X), stopped(X), expect(remaining_children, [{p, P}], lawspec_beam_actors:children(Sup))
    end).
limits() ->
    tree(one_for_one, 2, counters([a, b]), fun(Sup) ->
        [A, B] = children(Sup, [a, b]),
        lawspec_beam_actors:monitor(Sup, self()),
        lists:foreach(fun(_) -> fail_call(A) end, lists:seq(1, 3)),
        stopped(B), crashed(Sup),
        expect(one_limit_notification, {error, nil}, lawspec_beam_actors:receive_event(Sup, 0))
    end).
escalation() ->
    InnerSpec = lawspec_beam_actors:supervisor(one_for_one, 1, 10000000, counters([a, b])),
    tree(one_for_one, 5, [{inner, permanent, InnerSpec}, {c, permanent, counter()}], fun(Sup) ->
        [Inner, C] = children(Sup, [inner, c]), [A, B] = children(Inner, [a, b]),
        Old = lawspec_beam_actors:worker_pid(Inner),
        bump(B), bump(C), fail_call(A), fail_call(A),
        expect(escalated_children, [0, 0, 1], states([A, B, C])),
        expect(replaced_inner_supervisor, true, Old =/= lawspec_beam_actors:worker_pid(Inner)),
        expect(outer_restart_count, 1, lawspec_beam_actors:restart_count(Sup)),
        expect(fresh_inner_budget, 0, lawspec_beam_actors:restart_count(Inner))
    end).
links() ->
    lawspec_beam_actors:with_spec(counter(), fun(A) ->
        lawspec_beam_actors:with_spec(counter(), fun(B) ->
            lawspec_beam_actors:link(A, B), lawspec_beam_actors:monitor(B, self()),
            fail_call(A), crashed(B), stopped(B)
        end)
    end),
    tree(one_for_one, 10, counters([a, b, c]), fun(Sup) ->
        [A, B, C] = As = children(Sup, [a, b, c]),
        lawspec_beam_actors:link(A, B), lawspec_beam_actors:link(B, C), lawspec_beam_actors:link(C, A),
        lists:foreach(fun(X) -> bump(X), lawspec_beam_actors:monitor(X, self()) end, As),
        fail_call(A), lists:foreach(fun crashed/1, As),
        expect(link_cycle, [0, 0, 0], states(As)),
        expect(one_restart_per_linked_actor, 3, lawspec_beam_actors:restart_count(Sup))
    end).
checkpoint_and_mailbox() ->
    Spec = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> S end),
    tree(one_for_one, 5, [{a, permanent, Spec}], fun(Sup) ->
        [A] = children(Sup, [a]), bump(A), fail_call(A),
        expect(committed_checkpoint, 1, lawspec_beam_actors:state(A)),
        Owner = self(), Worker = lawspec_beam_actors:worker_pid(A),
        lawspec_beam_actors:monitor(A, Owner),
        lawspec_beam_actors:tell(A, fun(S) -> Owner ! {entered, self()}, receive finish -> {ok, S + 10} end end),
        receive {entered, Worker} -> ok after 2000 -> failure(mailbox_handler_started, Worker, timeout) end,
        lawspec_beam_actors:tell(A, fun(S) -> {ok, S + 2} end),
        exit(Worker, kill), crashed(A),
        expect(queued_tell_after_external_kill, 3, lawspec_beam_actors:state(A)),
        expect(stable_mailbox_handle, A, lawspec_beam_actors:child(Sup, a)),
        expect(replaced_killed_worker, true, Worker =/= lawspec_beam_actors:worker_pid(A))
    end).

queued_sibling_restart(Strategy) ->
    Owner = self(),
    Sibling = lawspec_beam_actors:actor(fun() -> 0 end, fun(S) -> Owner ! {restored, S}, 0 end),
    tree(Strategy, 5, [{a, permanent, counter()}, {b, permanent, Sibling}], fun(Sup) ->
        [A, B] = children(Sup, [a, b]), Worker = lawspec_beam_actors:worker_pid(B),
        lawspec_beam_actors:tell(B, fun(S) -> Owner ! {entered, self()}, receive finish -> {ok, S + 1} end end),
        receive {entered, Worker} -> ok after 2000 -> failure(sibling_started, Worker, timeout) end,
        try
            lawspec_beam_actors:tell(B, fun(S) -> Owner ! {queued_checkpoint, S}, {ok, S + 3} end),
            lawspec_beam_actors:tell(A, fun(_) -> error(supervision_probe) end),
            wait_for_restart(Sup, erlang:monotonic_time(millisecond) + 2000),
            %% This tell follows the restart; the two accepted earlier
            %% belong to the old checkpoint. Their order must survive OTP
            %% replacing the sibling while its first handler is blocked.
            lawspec_beam_actors:tell(B, fun(S) -> {ok, S + 10} end), Worker ! finish,
            expect({Strategy, post_restart_tell}, 10, lawspec_beam_actors:state(B)),
            receive {queued_checkpoint, Before} -> expect({Strategy, queued_checkpoint}, 1, Before)
                after 2000 -> failure(queued_checkpoint, 1, timeout) end,
            receive {restored, Checkpoint} -> expect({Strategy, restart_checkpoint}, 4, Checkpoint)
                after 2000 -> failure(restart_checkpoint, 4, timeout) end
        after Worker ! finish end
    end).
wait_for_restart(Sup, Deadline) ->
    case lawspec_beam_actors:restart_count(Sup) of
        0 ->
            expect(restart_admitted, true, erlang:monotonic_time(millisecond) < Deadline),
            receive after 1 -> ok end, wait_for_restart(Sup, Deadline);
        _ -> ok
    end.
