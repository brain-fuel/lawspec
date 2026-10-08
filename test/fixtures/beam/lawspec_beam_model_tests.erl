%% @doc Model generation and shrinking retain valid typestate, check both
%% reference and native states, and exercise real OTP actor restarts.
%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(lawspec_beam_model_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1, stack/0, counter/1, guarded/0]).

model(Sharing, Actor, StartArgs, StartIndices, Commands, Start, Abstract, Invariants) ->
    Forms = [<<"(machine sample ">>, Sharing, <<") (start (indices ">>, StartIndices,
        <<") (arguments ">>, StartArgs, <<")) ">>,
        [F || {F, _} <- Commands], <<"(abstract ">>, boolean(Abstract =/= none), <<") (invariants ">>,
        lists:join(<<" ">>, [K || {K, _} <- Invariants]),
        <<") (perkey false) (actor ">>, boolean(Actor), <<") (consistency linearizable)">>],
    lawspec_beam_model:new(iolist_to_binary(Forms), Start, [C || {_, C} <- Commands],
        Abstract, [F || {_, F} <- Invariants]).
boolean(true) -> <<"true">>;
boolean(false) -> <<"false">>.
command(Name, Arguments, Position, Unit, Needs, Shifts, Restart, Callbacks) ->
    {iolist_to_binary([<<"(command ">>, Name, <<" (arguments ">>, Arguments, <<") (state ">>,
        integer_to_binary(Position), <<") (unit ">>, boolean(Unit), <<") (when ">>,
        boolean(element(3, Callbacks) =/= none), <<") (needs ">>, Needs, <<") (shifts ">>, Shifts,
        <<") (key none) (restart ">>, boolean(Restart), <<")) ">>]), Callbacks}.
pair(A, B) -> {ls_data, <<"Pair::Pair">>, [A, B]}.
flow(S) -> {ls_data, <<"PushFlow">>, [S]}.

stack() ->
    Start = fun(_, [ls_unit]) -> [] end,
    Push = {fun(_, [N, S]) -> flow([N | S]) end, fun(_, [N, S]) -> [N | S] end, none},
    Pop = {fun(_, [[N | S]]) -> pair(N, S) end, fun(_, [[N | S]]) -> pair(N, S) end, none},
    Clear = {fun(_, [_]) -> flow([]) end, fun(_, [_]) -> [] end, none},
    model(<<"linear">>, false, <<"(unit)">>, <<"0">>, [
        command(<<"push">>, <<"(int Int8 -128 127)">>, 1, true, <<"(atleast 0)">>, <<"(by 1)">>, false, Push),
        command(<<"pop">>, <<>>, 0, false, <<"(atleast 1)">>, <<"(by -1)">>, false, Pop),
        command(<<"clear">>, <<>>, 0, true, <<"(atleast 0)">>, <<"(to 0)">>, false, Clear)],
        {Start, Start}, fun(_, [S]) -> S end, []).

counter(Actor) ->
    Start = {fun(_, [ls_unit]) -> case Actor of true -> 0; false -> atomics:new(1, []) end end,
        fun(_, [ls_unit]) -> 0 end},
    Add = {fun(_, [S, N]) -> case Actor of true -> pair(S + N, S + N); false -> atomics:add_get(S, 1, N) end end,
        fun(_, [N, S]) -> pair(S + N, S + N) end, none},
    Read = {fun(_, [S]) -> case Actor of true -> pair(S, S); false -> atomics:get(S, 1) end end,
        fun(_, [S]) -> pair(S, S) end, none},
    Close = {fun(_, [S]) -> case Actor of true -> 0; false -> atomics:put(S, 1, 0), ls_unit end end,
        fun(_, [_]) -> 0 end, none},
    Restart = {fun(_, [S]) -> S + 10 end, fun(_, [S]) -> S + 10 end, none},
    Commands = [command(<<"add">>, <<"(int UInt8 0 255)">>, 0, false, <<>>, <<>>, false, Add),
        command(<<"read">>, <<>>, 0, false, <<>>, <<>>, false, Read),
        command(<<"close">>, <<>>, 0, true, <<>>, <<>>, false, Close)] ++
        [command(<<"reopen">>, <<>>, 0, true, <<>>, <<>>, true, Restart) || Actor],
    model(<<"shared">>, Actor, <<"(unit)">>, <<>>, Commands, Start,
        fun(_, [S]) -> case Actor of true -> S; false -> atomics:get(S, 1) end end,
        [{<<"model">>, fun(_, [S]) -> S >= 0 end}]).

linear_typestate_and_flow_results_test() ->
    M = stack(), Run = {[ls_unit], [{0, [4]}, {0, [7]}, {1, []}, {2, []}]},
    ?assertEqual({ok, [[], [4], [7, 4], [4], []]}, lawspec_beam_model:simulate(M, Run)),
    ?assertEqual(ok, lawspec_beam_model:execute(M, Run)),
    ?assertEqual(invalid, lawspec_beam_model:simulate(M, {[ls_unit], [{1, []}]})),
    ?assertEqual({error, #{step => 1, reason => invalid_step}}, lawspec_beam_model:execute(M, {[ls_unit], [{1, []}]})),
    ?assertEqual(ok, lawspec_beam_model:check(M, #{seed => 0})).

shared_handle_results_and_invariants_test() ->
    M = counter(false),
    ?assertEqual(ok, lawspec_beam_model:check(M, #{seed => -1})),
    ?assertEqual(ok, lawspec_beam_model:execute(M, {[ls_unit], [{0, [4]}, {1, []}, {2, []}]})).

actor_unit_handlers_and_checkpoint_restarts_test() ->
    M = counter(true), Run = {[ls_unit], [{0, [7]}, {3, []}, {1, []}, {2, []}, {3, []}]},
    ?assertEqual({ok, [0, 7, 17, 17, 0, 10]}, lawspec_beam_model:simulate(M, Run)),
    ?assertEqual(ok, lawspec_beam_model:execute(M, Run)),
    ?assertEqual(ok, lawspec_beam_model:check(M, #{seed => 1234})).

actor_callbacks_run_inside_persistent_workers_test() ->
    Owner = self(),
    Start = fun(_, [N]) -> Owner ! {worker, start, self()}, N end,
    Add = fun(_, [S, N]) -> Owner ! {worker, add, self()}, pair(S + N, S + N) end,
    Ref = fun(_, [N, S]) -> pair(S + N, S + N) end,
    M = model(<<"shared">>, true, <<"(int UInt8 0 255)">>, <<>>, [
        command(<<"add">>, <<"(int UInt8 0 255)">>, 0, false, <<>>, <<>>, false, {Add, Ref, none})],
        {Start, fun(_, [N]) -> N end}, fun(_, [S]) -> S end, []),
    Run = {[5], [{0, [2]}, {0, [3]}, {1, []}, {0, [4]}]},
    ?assertEqual({ok, [5, 7, 10, 5, 9]}, lawspec_beam_model:simulate(M, Run)),
    ?assertEqual(ok, lawspec_beam_model:execute(M, Run)),
    P1 = worker(start), ?assertNotEqual(Owner, P1),
    ?assertEqual(P1, worker(add)), ?assertEqual(P1, worker(add)),
    P2 = worker(start), ?assertNotEqual(P1, P2), ?assertEqual(P2, worker(add)),
    ?assertNot(is_process_alive(P1)), ?assertNot(is_process_alive(P2)).
worker(Kind) -> receive {worker, Kind, Pid} -> Pid after 1000 -> error(no_worker) end.

actor_adapter_failure_closes_tree_test() ->
    Owner = self(),
    M0 = counter(true),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, _) -> Owner ! {worker, broken, self()}, error(broken_adapter) end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    ?assertMatch({error, #{step := 1, reason := {raised, error, {lawspec, {actor_crashed, _}}}}},
        lawspec_beam_model:execute(M, {[ls_unit], [{0, [1]}]})),
    Pid = worker(broken), ?assertNot(is_process_alive(Pid)).

references_and_preconditions_keep_generation_valid_test() ->
    M = guarded(),
    lists:foreach(fun(Seed) ->
        {Run, _} = lawspec_beam_model:generate(M, Seed, 100, 4, true),
        ?assertMatch({ok, _}, lawspec_beam_model:simulate(M, Run)),
        ?assertEqual(ok, lawspec_beam_model:execute(M, Run))
    end, lists:seq(0, 20)).
guarded() ->
    M0 = counter(false),
    Add = (lawspec_beam_model:command(M0, 0))#{'when' := fun(_, [S]) -> S < 20 end,
        reference := fun(_, [N, S]) when N < 5 -> pair(N + S, N + S) end},
    M0#{commands := {Add}, steps := {Add}}.

invalid_references_do_not_hide_implementation_failures_test() ->
    M0 = counter(false),
    BadStart = M0#{start_model := fun(_, _) -> error(invalid_start_reference) end},
    {Run, _} = lawspec_beam_model:generate(BadStart, 0, 20, 2, true),
    ?assertEqual({[ls_unit], []}, Run),
    ?assertMatch({error, #{step := 0, reason := {raised, error, invalid_start_reference}}},
        lawspec_beam_model:execute(BadStart, Run)),
    ?assertException(error, {lawspec, {model_failed, _, _}}, lawspec_beam_model:check(BadStart)).

checks_abstract_state_and_both_invariant_kinds_test() ->
    M0 = counter(false), Run = {[ls_unit], [{0, [1]}]},
    M1 = M0#{abstract := fun(_, _) -> 7 end},
    ?assertEqual({error, #{step => 0, reason => {state, 7, 0}}}, lawspec_beam_model:execute(M1, Run)),
    lists:foreach(fun({Kind, Inv}) ->
        M = M0#{invariants := [{Kind, Inv}]},
        ?assertEqual({error, #{step => 1, reason => {invariant, Kind}}}, lawspec_beam_model:execute(M, Run))
    end, [{<<"model">>, fun(_, [N]) -> N =:= 0 end},
        {<<"state">>, fun(_, [S]) -> atomics:get(S, 1) =:= 0 end}]),
    ?assertMatch({error, #{reason := {non_boolean_invariant, _, 1}}},
        lawspec_beam_model:execute(M0#{invariants := [{<<"model">>, fun(_, _) -> 1 end}]}, Run)).

shrinks_commands_and_arguments_to_failing_minimum_test() ->
    M0 = counter(false),
    Add = (lawspec_beam_model:command(M0, 0))#{run := fun(_, [S, N]) ->
        atomics:add_get(S, 1, N) + case N of 0 -> 0; _ -> 1 end end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    Run = {[ls_unit], [{1, []}, {0, [8]}, {1, []}, {0, [100]}]},
    {error, Failure} = lawspec_beam_model:execute(M, Run),
    {Small, Found} = lawspec_beam_model:shrink(M, Run, Failure, 100),
    ?assertEqual({[ls_unit], [{0, [1]}]}, Small),
    ?assertEqual(#{step => 1, reason => {returned, 2, 1}}, Found),
    ?assertEqual(<<"start(()); add(1)">>, lawspec_beam_model:describe(M, Small)),
    ?assertEqual({Run, Failure}, lawspec_beam_model:shrink(M, Run, Failure, 0)).

shrinks_start_arguments_test() ->
    M0 = counter(false),
    M = M0#{start_arguments := [[<<"int">>, <<"UInt8">>, 0, 255]],
        start_run := fun(_, [N]) -> N + case N of 0 -> 0; _ -> 1 end end,
        start_model := fun(_, [N]) -> N end, abstract := fun(_, [N]) -> N end},
    Run = {[99], []}, {error, Failure} = lawspec_beam_model:execute(M, Run),
    ?assertEqual({{[1], []}, #{step => 0, reason => {state, 2, 1}}},
        lawspec_beam_model:shrink(M, Run, Failure, 100)).

invalid_shrinks_do_not_call_native_adapters_test() ->
    M0 = stack(), Called = atomics:new(1, []),
    Pop = (lawspec_beam_model:command(M0, 1))#{run := fun(_, [[N | S]]) -> atomics:add(Called, 1, 1), pair(N + 1, S) end},
    M = M0#{steps := setelement(2, maps:get(steps, M0), Pop)},
    Run = {[ls_unit], [{0, [0]}, {1, []}]},
    {error, Failure} = lawspec_beam_model:execute(M, Run),
    ?assertEqual({Run, Failure}, lawspec_beam_model:shrink(M, Run, Failure, 100)),
    ?assertEqual(1, atomics:get(Called, 1)).

attempts_get_fresh_owned_contexts_test() ->
    Owner = self(),
    M0 = counter(false),
    Factory = fun(Body) ->
        Ref = make_ref(), Owner ! {opened, Ref},
        try Body(Ref) after Owner ! {closed, Ref} end
    end,
    Start = fun(Ref, [ls_unit]) -> Owner ! {used, Ref}, atomics:new(1, []) end,
    M = M0#{context := Factory, start_run := Start},
    ?assertEqual(ok, lawspec_beam_model:execute(M, {[ls_unit], []})),
    ?assertEqual(ok, lawspec_beam_model:execute(M, {[ls_unit], []})),
    Ref1 = receive {opened, R1} -> R1 end,
    receive {used, Ref1} -> ok end, receive {closed, Ref1} -> ok end,
    Ref2 = receive {opened, R2} -> R2 end,
    receive {used, Ref2} -> ok end, receive {closed, Ref2} -> ok end,
    ?assertNotEqual(Ref1, Ref2).

failure_records_replay_seed_case_and_shrunk_run_test() ->
    M = (counter(false))#{abstract := fun(_, _) -> 1 end},
    try lawspec_beam_model:check(M, #{seed => 8, cases => 1}) of
        _ -> error(expected_counterexample)
    catch error:{lawspec, {model_failed, <<"sample">>, Evidence}} ->
        ?assertMatch(#{seed := 8, 'case' := 0, run := _, description := _, failure := #{step := 0}}, Evidence),
        ?assertEqual({error, maps:get(failure, Evidence)}, lawspec_beam_model:execute(M, maps:get(run, Evidence)))
    end.

empty_case_set_is_rejected_test() ->
    ?assertError({lawspec, model_requires_cases}, lawspec_beam_model:check(stack(), #{cases => 0})).

malformed_consistency_cannot_silently_weaken_a_model_test() ->
    Start = fun(_, _) -> 0 end,
    Spec = fun(Mode) -> <<"(machine tiny shared) (start (indices) (arguments (unit))) ",
        "(abstract false) (invariants) (perkey false) (actor false) (consistency ", Mode/binary, ")">> end,
    ?assertError({lawspec, model_invalid_consistency},
        lawspec_beam_model:new(Spec(<<"unknown">>), {Start, Start}, [], none, [])),
    ?assertError({lawspec, model_eventual_requires_abstraction},
        lawspec_beam_model:new(Spec(<<"eventual">>), {Start, Start}, [], none, [])).

%% These vectors are produced by the committed Python model runtime. They
%% cover rejected preconditions, typestate, argument boundaries and crashes.
%% ref:DEC-portable-seeded-generation
vectors(Path) ->
    {ok, Bytes} = file:read_file(Path), Cases = json:decode(Bytes),
    lists:foreach(fun(#{<<"kind">> := Kind, <<"seed">> := Seed, <<"length">> := Length,
            <<"size">> := Size, <<"end">> := End, <<"run">> := Expected, <<"shrinks">> := Shrinks}) ->
        Model = case Kind of <<"stack">> -> stack(); <<"counter">> -> counter(false);
            <<"actor">> -> counter(true); <<"guarded">> -> guarded() end,
        {Run, Last} = lawspec_beam_model:generate(Model, lawspec_beam_random:seed(Seed), Length, Size, true),
        ?assertEqual(End, Last), ?assertEqual(Expected, lawspec_beam_model:describe(Model, Run)),
        ?assertEqual(Shrinks, [lawspec_beam_model:describe(Model, R) || R <- lawspec_beam_model:candidates(Model, Run)])
    end, Cases),
    io:format("~B BEAM model sequences and shrinks match the portable runtime.~n", [length(Cases)]).
