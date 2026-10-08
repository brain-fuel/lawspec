%% @doc Parallel model evidence checks actual overlapping calls and every
%% promised consistency mode, and shrinks only reference-valid histories.
%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(lawspec_beam_model_parallel_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1, histories/1]).

counter() -> lawspec_beam_model_tests:counter(false).
pair(A, B) -> {ls_data, <<"Pair::Pair">>, [A, B]}.
consistent(Model, Branches, History, Expected, Final) ->
    %% Pure history tests use the model invariants and supplied final state.
    lawspec_beam_model:with_context(Model, [ls_unit], fun(Context) ->
        lawspec_beam_model_parallel:consistent(Model, Context, Branches, History, Expected, Final, unused)
    end).

linearizable_histories_keep_real_time_test() ->
    M = counter(), Branches = [[{0, [1]}], [{1, []}]],
    ?assert(consistent(M, Branches, [[{1, 2, 1}], [{3, 4, 1}]], 0, {some, 1})),
    ?assertNot(consistent(M, Branches, [[{1, 2, 1}], [{3, 4, 0}]], 0, {some, 1})),
    ?assert(consistent(M, Branches, [[{1, 4, 1}], [{2, 3, 0}]], 0, {some, 1})).

sequential_histories_keep_each_callers_order_test() ->
    M = (counter())#{consistency := <<"sequential">>},
    ?assert(consistent(M, [[{0, [1]}], [{1, []}]], [[{1, 2, 1}], [{3, 4, 0}]], 0, {some, 1})),
    ?assertNot(consistent(M, [[{0, [1]}, {1, []}]], [[{1, 2, 1}, {3, 4, 0}]], 0, {some, 1})).

overlapping_results_need_one_consistent_order_test() ->
    M = counter(), B = [[{0, [1]}], [{0, [1]}]],
    ?assert(consistent(M, B, [[{1, 4, 2}], [{2, 3, 1}]], 0, {some, 2})),
    ?assertNot(consistent(M, B, [[{1, 4, 1}], [{2, 3, 1}]], 0, {some, 2})),
    ?assertNot(consistent(M, B, [[{1, 4, 2}], [{2, 3, 1}]], 0, {some, 1})).

eventual_checks_final_state_and_invariants_test() ->
    M = (counter())#{consistency := <<"eventual">>},
    B = [[{0, [1]}], [{0, [1]}]], H = [[{1, 4, 999}], [{2, 3, 999}]],
    ?assert(consistent(M, B, H, 0, {some, 2})),
    ?assertNot(consistent(M, B, H, 0, {some, 1})),
    BadInvariant = M#{invariants := [{<<"model">>, fun(_, [S]) -> S < 2 end}]},
    ?assertNot(consistent(BadInvariant, B, H, 0, {some, 2})).

causal_checks_individual_views_without_global_final_equality_test() ->
    M = (counter())#{consistency := <<"causal">>}, B = [[{0, [1]}], [{0, [1]}]],
    ?assert(consistent(M, B, [[{1, 4, 1}], [{2, 3, 1}]], 0, {some, 2})),
    ?assertNot(consistent(M, B, [[{1, 4, 1}], [{2, 3, 2}]], 0, {some, 2})),
    BadInvariant = M#{invariants := [{<<"model">>, fun(_, [S]) -> S =:= 0 end}]},
    ?assertNot(consistent(BadInvariant, B, [[{1, 4, 1}], [{2, 3, 1}]], 0, none)).

partitions_independent_keys_and_falls_back_for_global_commands_test() ->
    M0 = counter(),
    Put = (lawspec_beam_model:command(M0, 0))#{key := 0,
        reference := fun(_, [K, S]) ->
            N = maps:get(K, S, 0) + 1, pair(N, S#{K => N}) end},
    M = M0#{per_key := true, commands := {Put}, steps := {Put}, invariants := []},
    B = [[{0, [1]}, {0, [2]}], [{0, [2]}, {0, [1]}]],
    H = [[{1, 4, 1}, {5, 6, 2}], [{2, 3, 1}, {7, 8, 2}]],
    ?assert(consistent(M, B, H, #{}, {some, #{1 => 2, 2 => 2}})),
    ?assertNot(consistent(M, B, H, #{}, {some, #{1 => 1, 2 => 2}})),
    Bad = [[{1, 4, 1}, {5, 6, 1}], [{2, 3, 1}, {7, 8, 2}]],
    ?assertNot(consistent(M, B, Bad, #{}, none)),
    Global = Put#{key := none},
    ?assert(consistent(M#{steps := {Global}}, B, H, #{}, {some, #{1 => 2, 2 => 2}})).

every_interleaving_must_be_reference_valid_test() ->
    M0 = counter(),
    Take = (lawspec_beam_model:command(M0, 1))#{
        'when' := fun(_, [S]) -> S > 0 end, reference := fun(_, [S]) -> pair(S - 1, S - 1) end},
    M = M0#{commands := setelement(2, maps:get(commands, M0), Take), steps := setelement(2, maps:get(steps, M0), Take)},
    Prefix = {[ls_unit], [{0, [1]}]},
    ?assert(lawspec_beam_model_parallel:allowed(M, {Prefix, [[{1, []}], []]})),
    ?assertNot(lawspec_beam_model_parallel:allowed(M, {Prefix, [[{1, []}], [{1, []}]]})),
    lists:foreach(fun(Seed) ->
        {Case, _} = lawspec_beam_model_parallel:generate(M, Seed, 4, 3, 5),
        ?assert(lawspec_beam_model_parallel:allowed(M, Case))
    end, lists:seq(0, 30)).

key_search_backtracks_until_the_final_abstraction_matches_test() ->
    M0 = counter(),
    Put = (lawspec_beam_model:command(M0, 0))#{key := 0, unit := true,
        reference := fun(_, [K, V, S]) -> S#{K => V} end},
    M = M0#{per_key := true, commands := {Put}, steps := {Put}, invariants := []},
    B = [[{0, [1, 1]}, {0, [2, 3]}], [{0, [1, 2]}, {0, [2, 4]}]],
    H = [[{1, 6, ls_unit}, {7, 12, ls_unit}], [{2, 5, ls_unit}, {8, 11, ls_unit}]],
    ?assert(consistent(M, B, H, #{}, {some, #{1 => 1, 2 => 3}})),
    ?assert(consistent(M, B, H, #{}, {some, #{1 => 2, 2 => 4}})),
    ?assertNot(consistent(M, B, H, #{}, {some, #{1 => 2, 2 => 5}})).

weaker_consistency_keeps_process_order_across_keys_test() ->
    M0 = counter(),
    Put = (lawspec_beam_model:command(M0, 0))#{key := 0, unit := true,
        reference := fun(_, [K, V, S]) -> S#{K => V} end},
    M = M0#{per_key := true, commands := {Put}, steps := {Put}, invariants := []},
    %% X ends with A's write and Y with B's only if Bx < Ax < Ay < By < Bx.
    %% Each key alone permits this, but no global process-preserving order does.
    B = [[{0, [1, 1]}, {0, [2, 1]}], [{0, [2, 2]}, {0, [1, 2]}]],
    H = [[{1, 4, ls_unit}, {5, 8, ls_unit}], [{2, 3, ls_unit}, {6, 7, ls_unit}]],
    lists:foreach(fun(Mode) ->
        ?assertNot(consistent(M#{consistency := Mode}, B, H, #{}, {some, #{1 => 1, 2 => 2}})),
        ?assert(consistent(M#{consistency := Mode}, B, H, #{}, {some, #{1 => 2, 2 => 2}}))
    end, [<<"sequential">>, <<"eventual">>]).

actual_atomic_counter_and_actor_histories_test() ->
    lists:foreach(fun(M) ->
        ?assertEqual(ok, lawspec_beam_model_parallel:check(M, #{cases => 4, repeats => 2, seed => 15}))
    end, [counter(), lawspec_beam_model_tests:counter(true)]).

actual_overlap_exposes_lost_updates_test() ->
    M0 = counter(),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, [S, N]) ->
        Before = atomics:get(S, 1), atomics:add(S, 2, 1),
        wait(fun() -> atomics:get(S, 2) =:= 2 end),
        atomics:put(S, 1, Before + N), Before + N
    end},
    M = M0#{start_run := fun(_, _) -> atomics:new(2, []) end,
        steps := setelement(1, maps:get(steps, M0), Add)},
    Case = {{[ls_unit], []}, [[{0, [1]}], [{0, [1]}]]},
    ?assertMatch({error, #{reason := no_consistent_order}}, lawspec_beam_model_parallel:execute(M, Case, 0)).

native_exceptions_wait_for_all_sibling_workers_test() ->
    M0 = counter(), Owner = self(),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, [_, N]) ->
        Owner ! {worker, self()},
        case N of 1 -> error(broken_command); _ -> receive after 20 -> Owner ! finished end, 0 end
    end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    ?assertMatch({error, #{reason := {raised, error, broken_command}}},
        lawspec_beam_model_parallel:execute(M, {{[ls_unit], []}, [[{0, [1]}], [{0, [2]}]]}, 0)),
    Pids = [receive {worker, P} -> P after 1000 -> error(missing_worker) end || _ <- [1, 2]],
    receive finished -> ok after 0 -> error(sibling_not_joined) end,
    ?assert(lists:all(fun(P) -> not is_process_alive(P) end, Pids)).

caller_death_cancels_parallel_native_calls_test() ->
    M0 = counter(), Owner = self(),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, _) ->
        Owner ! {worker, self()}, receive forever -> 0 end end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    Runner = spawn(fun() -> lawspec_beam_model_parallel:execute(M,
        {{[ls_unit], []}, [[{0, [1]}], [{0, [1]}]]}, 0) end),
    Pids = [receive {worker, P} -> P after 1000 -> error(missing_worker) end || _ <- [1, 2]],
    exit(Runner, kill),
    wait(fun() -> lists:all(fun(P) -> not is_process_alive(P) end, Pids) end).

shrinks_a_parallel_counterexample_and_reports_seed_test() ->
    M0 = counter(),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, [S, N]) ->
        atomics:add_get(S, 1, N) + case N of 0 -> 0; _ -> 1 end end},
    M = M0#{commands := {Add}, steps := {Add}},
    Case = {{[ls_unit], []}, [[{0, [9]}], [{0, [8]}]]},
    {error, Failure} = lawspec_beam_model_parallel:execute(M, Case, 0),
    {Small, _} = lawspec_beam_model_parallel:shrink(M, Case, Failure, 1, 100, 0),
    ?assertEqual({{[ls_unit], []}, [[], [{0, [1]}]]}, Small),
    ?assertEqual(<<"start(()), then A: nothing and B: add(1) at the same time">>,
        lawspec_beam_model_parallel:describe(M, Small)),
    try lawspec_beam_model_parallel:check(M, #{cases => 1, repeats => 1, seed => 0, max_shrinks => 0}) of
        _ -> error(expected_counterexample)
    catch error:{lawspec, {model_inconsistent, <<"sample">>, <<"linearizable">>, Evidence}} ->
        ?assertMatch(#{seed := 0, 'case' := 0, shake := _, run := _, failure := _}, Evidence)
    end.

wait(Predicate) -> wait(Predicate, erlang:monotonic_time(millisecond) + 2000).
wait(Predicate, Deadline) -> case Predicate() of true -> ok; false ->
    case erlang:monotonic_time(millisecond) >= Deadline of true -> error(wait_timeout);
        false -> receive after 1 -> wait(Predicate, Deadline) end end end.

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path), Cases = json:decode(Bytes),
    lists:foreach(fun(#{<<"kind">> := Kind, <<"seed">> := Seed, <<"size">> := Size,
            <<"threads">> := Threads, <<"length">> := Length, <<"end">> := End, <<"run">> := Expected,
            <<"shrinks">> := Shrinks}) ->
        Model = case Kind of <<"counter">> -> counter(); <<"actor">> -> lawspec_beam_model_tests:counter(true);
            <<"guarded">> -> lawspec_beam_model_tests:guarded() end,
        {Run, Last} = lawspec_beam_model_parallel:generate(Model, lawspec_beam_random:seed(Seed), Size, Threads, Length),
        ?assertEqual(End, Last), ?assertEqual(Expected, lawspec_beam_model_parallel:describe(Model, Run)),
        ?assertEqual(Shrinks, [lawspec_beam_model_parallel:describe(Model, R) || R <- lawspec_beam_model_parallel:candidates(Model, Run)])
    end, Cases),
    io:format("~B BEAM parallel model sequences and shrinks match the portable runtime.~n", [length(Cases)]).

histories(Path) ->
    {ok, Bytes} = file:read_file(Path), Cases = json:decode(Bytes),
    lists:foreach(fun(#{<<"mode">> := Mode, <<"branches">> := Branches, <<"history">> := History,
            <<"initial">> := Initial, <<"final">> := Final, <<"consistent">> := Expected}) ->
        Model = (counter())#{consistency := Mode},
        B = [[{I, Args} || [I, Args] <- Branch] || Branch <- Branches],
        H = [[{A, R, V} || [A, R, V] <- Events] || Events <- History],
        F = case Final of null -> none; _ -> {some, Final} end,
        ?assertEqual(Expected, consistent(Model, B, H, Initial, F))
    end, Cases),
    io:format("~B BEAM concurrent histories match the portable consistency checker.~n", [length(Cases)]).
