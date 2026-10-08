%% @doc Stateful dependency cycles, valid contention and worker context lifetime.
%% ref:DEC-tests-cite-requirements ref:DEC-typed-core-boundary
-module(lawspec_beam_waits_tests).
-include_lib("eunit/include/eunit.hrl").

scope(Body) -> lawspec_beam_effects:with_scope(#{}, #{}, fun(_) -> Body() end).
cell() -> lawspec_beam_effects:native_cell(0).
read(Cell) -> lawspec_beam_effects:native_read(Cell).

direct_native_recursion_rejects_without_changing_state_test() ->
    scope(fun() ->
        Cell = cell(),
        ?assertError({lawspec, cyclic_handler_dependency},
            lawspec_beam_handler:call(Cell, fun(_) -> {read(Cell), 9} end)),
        ?assertEqual(0, read(Cell))
    end).

concurrent_cycles_reject_one_edge_and_release_every_caller_test_() ->
    [?_test(scope(fun() -> cycle([cell() || _ <- lists:seq(1, Size)], Parallel) end))
        || Size <- [2, 3], Parallel <- [false, true]].

cycles_across_nested_scopes_are_detected_test() ->
    scope(fun() ->
        Outer = cell(),
        scope(fun() -> cycle([Outer, cell()], false) end)
    end).

cycle(Cells, Parallel) ->
    Test = self(), Tag = make_ref(),
    Pairs = lists:zip(Cells, tl(Cells) ++ [hd(Cells)]),
    Callers = [spawn_monitor(fun() ->
        Result = try lawspec_beam_handler:call(Current, fun(State) ->
            Test ! {Tag, ready, self()},
            receive {Tag, go} -> ok end,
            Value = case Parallel of
                false -> read(Next);
                true -> hd(lawspec_beam_runtime:concurrently([fun() -> read(Next) end]))
            end,
            {Value, State + 1}
        end) of V -> {ok, V} catch error:Reason -> {error, Reason} end,
        Test ! {Tag, result, self(), Result}
    end) || {Current, Next} <- Pairs],
    try
        Workers = [receive {Tag, ready, Pid} -> Pid after 1000 -> error(worker_not_started) end || _ <- Cells],
        lists:foreach(fun(Pid) -> Pid ! {Tag, go} end, Workers),
        Results = [receive {Tag, result, Pid, R} -> R after 1000 -> error(handler_deadlocked) end || {Pid, _} <- Callers],
        ?assertEqual([{error, {lawspec, cyclic_handler_dependency}}], [R || R = {error, _} <- Results]),
        ?assertEqual(length(Cells) - 1, lists:sum([read(Cell) || Cell <- Cells])),
        lists:foreach(fun({Pid, Monitor}) ->
            receive {'DOWN', Monitor, process, Pid, normal} -> ok after 1000 -> error(caller_leaked) end
        end, Callers)
    after
        lists:foreach(fun({Pid, _}) -> exit(Pid, kill) end, Callers)
    end.

ordinary_contention_does_not_look_like_a_cycle_test() ->
    scope(fun() ->
        Shared = cell(),
        Cells = [cell() || _ <- lists:seq(1, 30)],
        Values = lawspec_beam_runtime:concurrently([fun() ->
            lawspec_beam_handler:call(Cell, fun(State) ->
                Value = lawspec_beam_handler:call(Shared, fun(N) -> {N + 1, N + 1} end),
                {Value, State + 1}
            end)
        end || Cell <- Cells]),
        ?assertEqual(lists:seq(1, 30), lists:sort(Values)),
        ?assertEqual(30, read(Shared)),
        ?assert(lists:all(fun(Cell) -> read(Cell) =:= 1 end, Cells))
    end).

native_allocation_in_workers_keeps_scope_lifetime_test() ->
    PrivateKey = {?MODULE, application_private},
    put(PrivateKey, secret),
    Cells = try scope(fun() ->
        Parent = cell(),
        FromClause = lawspec_beam_handler:call(Parent, fun(State) ->
            ?assertEqual(undefined, get(PrivateKey)),
            {lawspec_beam_effects:native_cell(42), State}
        end),
        [FromParallel] = lawspec_beam_runtime:concurrently([fun() ->
            ?assertEqual(undefined, get(PrivateKey)),
            lawspec_beam_effects:native_cell(43)
        end]),
        ?assertEqual(42, read(FromClause)),
        ?assertEqual(43, read(FromParallel)),
        [FromClause, FromParallel]
    end) after erase(PrivateKey) end,
    ?assert(lists:all(fun(Cell) -> not is_process_alive(Cell) end, Cells)).

last_cell_releases_the_tracker_test() ->
    {Graph, Monitor} = scope(fun() ->
        Graph = maps:get(graph, sys:get_state(cell())),
        {Graph, monitor(process, Graph)}
    end),
    receive {'DOWN', Monitor, process, Graph, normal} -> ok after 1000 -> error(tracker_leaked) end.

tracker_failure_closes_cells_and_busy_workers_test() ->
    Test = self(),
    scope(fun() ->
        Cell = cell(),
        Graph = maps:get(graph, sys:get_state(Cell)),
        Caller = spawn(fun() ->
            try lawspec_beam_handler:call(Cell, fun(_) ->
                Test ! {busy, self()}, receive forever -> {no, 1} end end)
            catch exit:_ -> ok end
        end),
        Worker = receive {busy, Pid} -> Pid after 1000 -> error(no_worker) end,
        Monitors = [{Pid, monitor(process, Pid)} || Pid <- [Cell, Caller, Worker]],
        exit(Graph, kill),
        lists:foreach(fun({Pid, M}) ->
            receive {'DOWN', M, process, Pid, _} -> ok after 1000 -> error({leaked, Pid}) end
        end, Monitors)
    end).

completed_dependencies_are_removed_before_reply_consumption_test() ->
    graph(fun(G, A, B) ->
        RA = root_request(G, A, self()),
        AB = make_ref(),
        ok = lawspec_beam_waits:request(G, AB, B, self(), {G, A, RA}),
        true = lawspec_beam_waits:activate(G, B, AB),
        ok = lawspec_beam_waits:complete(G, AB),
        RB = root_request(G, B, self()),
        %% A has not consumed its reply yet, but it no longer waits for B.
        ?assertEqual(ok, lawspec_beam_waits:request(G, make_ref(), A, self(), {G, B, RB}))
    end).

completed_origin_does_not_hold_a_cell_in_a_later_task_test() ->
    graph(fun(G, A, B) ->
        RA = root_request(G, A, self()),
        ok = lawspec_beam_waits:request(G, make_ref(), B, self(), {G, A, RA}),
        ok = lawspec_beam_waits:complete(G, RA),
        RB = root_request(G, B, self()),
        ?assertEqual(ok, lawspec_beam_waits:request(G, make_ref(), A, self(), {G, B, RB})),
        ?assertEqual(ok, lawspec_beam_waits:request(G, make_ref(), A, self(), {G, A, RA}))
    end).

cancelled_callers_do_not_leave_false_dependencies_test() ->
    graph(fun(G, A, B) ->
        Root = spawn(fun() -> receive stop -> ok end end),
        Monitor = monitor(process, Root),
        RA = root_request(G, A, Root),
        ok = lawspec_beam_waits:request(G, make_ref(), B, self(), {G, A, RA}),
        RB = root_request(G, B, self()),
        exit(Root, kill),
        receive {'DOWN', Monitor, process, Root, killed} -> ok end,
        ?assertEqual(ok, lawspec_beam_waits:request(G, make_ref(), A, self(), {G, B, RB}))
    end).

root_request(Graph, Cell, Caller) ->
    Token = make_ref(),
    ok = lawspec_beam_waits:request(Graph, Token, Cell, Caller, undefined),
    true = lawspec_beam_waits:activate(Graph, Cell, Token),
    Token.

graph(Body) ->
    A = spawn(fun() -> receive stop -> ok end end),
    B = spawn(fun() -> receive stop -> ok end end),
    Graph = lawspec_beam_waits:register(A),
    Graph = lawspec_beam_waits:register(B),
    try Body(Graph, A, B) after
        lawspec_beam_waits:unregister(Graph, A),
        lawspec_beam_waits:unregister(Graph, B),
        exit(A, kill), exit(B, kill)
    end.
