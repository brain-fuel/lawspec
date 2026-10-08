%% @doc Native boundaries and parallel groups preserve portable semantics.
%% ref:DEC-tests-cite-requirements
-module(lawspec_beam_runtime_tests).
-include_lib("eunit/include/eunit.hrl").

%% ref:DEC-native-bindings-typed-identity
native_absence_and_raw_test() ->
    S = lawspec_beam_schema:new([], [<<"Unit">>, <<"Null">>, <<"Undefined">>,
        <<"Utf16Text">>, <<"Int8">>], 32),
    Cases = [
        {<<"Unit">>, ls_unit, ok},
        {<<"Null">>, ls_null, null},
        {<<"Undefined">>, ls_undefined, undefined},
        {<<"Utf16Text">>, {ls_raw, <<"Utf16Text">>, [16#d800]}, [16#d800]},
        {<<"Optional (Nullable Int8)">>, {ls_presence, <<"Optional">>, none}, none},
        {<<"Optional (Nullable Int8)">>,
            {ls_presence, <<"Optional">>, {some, {ls_presence, <<"Nullable">>, none}}}, {some, null}},
        {<<"Optional (Nullable Int8)">>,
            {ls_presence, <<"Optional">>, {some, {ls_presence, <<"Nullable">>, {some, 42}}}}, {some, {non_null, 42}}}
    ],
    lists:foreach(fun({T, Canonical, Native}) ->
        ?assertEqual(Native, lawspec_beam_schema:to_native(Canonical, T, S)),
        ?assertEqual(Canonical, lawspec_beam_schema:from_native(Native, T, S)),
        ?assertEqual(lawspec_beam_scalar:type(T), lawspec_beam_scalar:type(
            lawspec_beam_schema:type_key(lawspec_beam_scalar:type(T))))
    end, Cases).

%% ref:DEC-portable-exact-arithmetic
contract_failures_are_contextual_test() ->
    ?assertError({lawspec, {<<"definition">>, {contract_failed, <<"precondition">>}}},
        lawspec_beam_runtime:contextual(<<"definition">>, fun() ->
            lawspec_beam_runtime:require(false, <<"precondition">>) end)),
    ?assertError({lawspec, {non_boolean_contract, <<"law">>}}, lawspec_beam_runtime:require(1, <<"law">>)).

%% ref:DEC-portable-exact-arithmetic
equation_failure_retains_values_test() ->
    ?assertError({lawspec, {equation_failed, <<"law">>, {actual, 2}, {expected, 3}}},
        lawspec_beam_runtime:assert_equal(2, 3, <<"law">>)),
    ?assertEqual(true, lawspec_beam_runtime:assert_equal(2, lawspec_beam_scalar:ratio(2, 1), <<"law">>)).

%% ref:DEC-typed-core-boundary
parallel_source_order_test() ->
    Test = self(),
    Worker = fun(N) -> fun() -> Test ! {started, N, self()}, receive go -> N end end end,
    {Caller, Monitor} = spawn_monitor(fun() ->
        Test ! {result, lawspec_beam_runtime:concurrently([Worker(1), Worker(2)])}
    end),
    P1 = receive {started, 1, One} -> One after 1000 -> error(first_did_not_start) end,
    P2 = receive {started, 2, Two} -> Two after 1000 -> error(second_did_not_start) end,
    P2 ! go, P1 ! go,
    receive {result, Values} -> ?assertEqual([1, 2], Values) after 1000 -> error(no_result) end,
    receive {'DOWN', Monitor, process, Caller, normal} -> ok after 1000 -> error(caller_did_not_stop) end.

%% ref:DEC-typed-core-boundary
parallel_failure_cancels_siblings_test() ->
    Test = self(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Result = try lawspec_beam_runtime:concurrently([
            fun() -> Test ! {failing, self()}, receive crash -> erlang:error(broken) end end,
            fun() -> Test ! {sibling, self()}, receive forever -> never end end
        ]) catch error:broken -> failed end,
        Test ! {result, Result}
    end),
    Failing = receive {failing, F} -> F after 1000 -> error(failing_did_not_start) end,
    Sibling = receive {sibling, P} -> P after 1000 -> error(sibling_did_not_start) end,
    Failing ! crash,
    receive {result, Result} -> ?assertEqual(failed, Result) after 1000 -> error(no_result) end,
    ?assertNot(is_process_alive(Sibling)),
    receive {'DOWN', Monitor, process, Caller, normal} -> ok after 1000 -> error(caller_did_not_stop) end.

%% ref:DEC-typed-core-boundary
parallel_caller_death_cancels_children_test() ->
    Test = self(),
    Caller = spawn(fun() -> lawspec_beam_runtime:concurrently([
        fun() -> Test ! {child, self()}, receive forever -> never end end]) end),
    Pid = receive {child, Child} -> Child after 1000 -> error(child_did_not_start) end,
    Monitor = monitor(process, Pid),
    exit(Caller, kill),
    receive {'DOWN', Monitor, process, Pid, killed} -> ok after 1000 -> error(child_leaked) end.

%% ref:DEC-typed-core-boundary
parallel_coordinator_death_cannot_leak_children_test() ->
    Test = self(),
    {Caller, CallerMonitor} = spawn_monitor(fun() ->
        try lawspec_beam_runtime:concurrently([
            fun() -> Test ! {child, self()}, receive forever -> never end end])
        catch error:{lawspec, {concurrent_group_failed, killed}} -> ok end
    end),
    Child = receive {child, Pid} -> Pid after 1000 -> error(child_did_not_start) end,
    {links, [Coordinator]} = process_info(Child, links),
    ChildMonitor = monitor(process, Child),
    exit(Coordinator, kill),
    receive {'DOWN', ChildMonitor, process, Child, killed} -> ok after 1000 -> error(child_leaked) end,
    receive {'DOWN', CallerMonitor, process, Caller, normal} -> ok after 1000 -> error(caller_leaked) end.

%% ref:DEC-typed-core-boundary
worker_context_restores_after_failure_test() ->
    Key = {lawspec_beam_effects, scope},
    Previous = put(Key, original),
    try
        ?assertThrow(abort, lawspec_beam_runtime:with_worker_context([{Key, replacement}], fun() ->
            ?assertEqual(replacement, get(Key)), throw(abort) end)),
        ?assertEqual(original, get(Key))
    after
        case Previous of undefined -> erase(Key); _ -> put(Key, Previous) end
    end.
