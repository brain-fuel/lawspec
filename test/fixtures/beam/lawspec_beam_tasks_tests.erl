%% @doc Structured cancellation reaches nested workers before it returns.
%% ref:DEC-tests-cite-requirements ref:DEC-async-native-tasks
-module(lawspec_beam_tasks_tests).
-include_lib("eunit/include/eunit.hrl").

close_joins_grandchildren_even_when_their_coordinator_is_suspended_test() ->
    Test = self(),
    lawspec_beam_tasks:with_scope(fun(Scope) ->
        Context = lawspec_beam_runtime:worker_context(),
        {Caller, Monitor} = spawn_monitor(fun() ->
            lawspec_beam_runtime:with_worker_context(Context, fun() ->
                lawspec_beam_runtime:async_call(fun() ->
                    lawspec_beam_runtime:concurrently([fun() ->
                        Test ! {grandchild, self()}, receive forever -> never end
                    end])
                end)
            end)
        end),
        Grandchild = receive {grandchild, Pid} -> Pid after 1000 -> error(no_grandchild) end,
        {links, Links} = process_info(Grandchild, links),
        [Coordinator] = Links -- [Scope],
        true = erlang:suspend_process(Coordinator),
        try
            ok = lawspec_beam_tasks:close(Scope),
            ?assertNot(is_process_alive(Grandchild)),
            ?assertNot(is_process_alive(Coordinator)),
            ?assertNot(is_process_alive(Caller)),
            receive {'DOWN', Monitor, process, Caller, killed} -> ok after 1000 -> error(caller_leaked) end
        after
            case is_process_alive(Coordinator) of true -> erlang:resume_process(Coordinator); false -> ok end
        end
    end).

nested_scopes_are_owned_by_every_ancestor_test() ->
    Test = self(),
    lawspec_beam_tasks:with_scope(fun(Outer) ->
        lawspec_beam_tasks:with_scope(fun(Inner) ->
            Context = lawspec_beam_runtime:worker_context(),
            spawn(fun() -> lawspec_beam_runtime:with_worker_context(Context, fun() ->
                Test ! {worker, self()}, receive forever -> never end
            end) end),
            Worker = receive {worker, Pid} -> Pid after 1000 -> error(no_worker) end,
            ?assert(maps:is_key(Worker, maps:get(workers, sys:get_state(Outer)))),
            ?assert(maps:is_key(Worker, maps:get(workers, sys:get_state(Inner)))),
            ok = lawspec_beam_tasks:close(Outer),
            ?assertNot(is_process_alive(Worker))
        end)
    end).

owner_death_cancels_workers_test() ->
    Test = self(),
    Owner = spawn(fun() -> lawspec_beam_tasks:with_scope(fun(Scope) ->
        Context = lawspec_beam_runtime:worker_context(),
        spawn(fun() -> lawspec_beam_runtime:with_worker_context(Context, fun() ->
            process_flag(trap_exit, true),
            Test ! {worker, Scope, self()}, receive forever -> never end
        end) end),
        receive forever -> never end
    end) end),
    {Scope, Worker} = receive {worker, S, P} -> {S, P} after 1000 -> error(no_worker) end,
    Monitor = monitor(process, Worker), ScopeMonitor = monitor(process, Scope),
    exit(Owner, kill),
    receive {'DOWN', Monitor, process, Worker, killed} -> ok after 1000 -> error(worker_leaked) end,
    receive {'DOWN', ScopeMonitor, process, Scope, normal} -> ok after 1000 -> error(scope_leaked) end.

closed_scope_never_runs_late_application_code_test() ->
    Test = self(),
    lawspec_beam_tasks:with_scope(fun(Scope) ->
        Context = lawspec_beam_runtime:worker_context(),
        ok = lawspec_beam_tasks:close(Scope),
        {Pid, Monitor} = spawn_monitor(fun() ->
            try lawspec_beam_runtime:with_worker_context(Context, fun() -> Test ! forbidden end)
            catch exit:_ -> ok end
        end),
        receive {'DOWN', Monitor, process, Pid, normal} -> ok after 1000 -> error(child_leaked) end,
        receive forbidden -> error(late_application_code_ran) after 0 -> ok end
    end).

scope_context_restores_on_exception_test() ->
    Key = {lawspec_beam_tasks, scopes},
    ?assertEqual(undefined, get(Key)),
    ?assertThrow(stopped, lawspec_beam_tasks:with_scope(fun(_) -> throw(stopped) end)),
    ?assertEqual(undefined, get(Key)).
