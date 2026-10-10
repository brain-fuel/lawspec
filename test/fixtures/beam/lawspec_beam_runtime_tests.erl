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
parallel_failure_joins_siblings_test() ->
    Test = self(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Result = try lawspec_beam_runtime:concurrently([
            fun() -> Test ! {failing, self()}, receive crash -> erlang:error(broken) end end,
            fun() -> Test ! {sibling, self()}, receive finish -> finished end end
        ]) catch error:broken -> failed end,
        Test ! {result, Result}
    end),
    Failing = receive {failing, F} -> F after 1000 -> error(failing_did_not_start) end,
    Sibling = receive {sibling, P} -> P after 1000 -> error(sibling_did_not_start) end,
    Failing ! crash,
    receive {result, _} -> error(returned_before_sibling_finished) after 10 -> ok end,
    Sibling ! finish,
    receive {result, Result} -> ?assertEqual(failed, Result) after 1000 -> error(no_result) end,
    ?assertNot(is_process_alive(Sibling)),
    receive {'DOWN', Monitor, process, Caller, normal} -> ok after 1000 -> error(caller_did_not_stop) end.

%% ref:DEC-async-native-tasks
parallel_exceptions_keep_declaration_order_test() ->
    Test = self(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        try lawspec_beam_runtime:concurrently([
            fun() -> Test ! {first, self()}, receive finish -> throw(first) end end,
            fun() -> Test ! {second, self()}, error(second) end
        ]) catch Class:Reason -> Test ! {result, Class, Reason} end
    end),
    First = receive {first, F} -> F after 1000 -> error(first_did_not_start) end,
    Second = receive {second, S} -> S after 1000 -> error(second_did_not_start) end,
    SecondMonitor = monitor(process, Second),
    receive {'DOWN', SecondMonitor, process, Second, _} -> ok after 1000 -> error(second_did_not_finish) end,
    receive {result, _, _} -> error(returned_before_first_finished) after 10 -> ok end,
    First ! finish,
    receive {result, throw, first} -> ok after 1000 -> error(wrong_exception) end,
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

%% ref:DEC-async-native-tasks
async_call_runs_in_an_isolated_worker_test() ->
    Key = {?MODULE, private},
    put(Key, private_value),
    try
        {Pid, Value} = lawspec_beam_runtime:async_call(fun() -> {self(), get(Key)} end),
        ?assertNotEqual(self(), Pid),
        ?assertEqual(undefined, Value),
        ?assertNot(is_process_alive(Pid)),
        ?assertEqual(private_value, get(Key))
    after erase(Key) end.

%% ref:DEC-async-native-tasks
async_exception_class_and_original_stack_are_preserved_test() ->
    ?assertThrow({typed_failure, 42}, lawspec_beam_runtime:async_call(fun() -> throw({typed_failure, 42}) end)),
    ?assertExit(stopped, lawspec_beam_runtime:async_call(fun() -> exit(stopped) end)),
    try lawspec_beam_runtime:async_call(fun async_error/0) of
        _ -> error(missing_exception)
    catch error:async_error:Stack ->
        ?assertMatch([{?MODULE, async_error, 0, _} | _], Stack)
    end.

async_error() -> error(async_error).

%% ref:REQ-law-primitives
recording_reads_portable_values_test() -> with_recording_folder(fun(Folder) ->
    Key = <<"example.tables/structured">>,
    Value = {ls_data, <<"example.tables::Order::Shipped">>, [7, <<"雪\"\\\n"/utf8>>]},
    Text = <<"Shipped(7, \"雪\\\"\\\\\n\")"/utf8>>,
    Path = filename:join(Folder, binary_to_list(Key)),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<Text/binary, "\n">>),
    ?assertEqual(true, recording(Key, Value)),
    ?assertEqual({ok, <<Text/binary, "\n">>}, file:read_file(Path)),
    ok = file:write_file(Path, Text),
    ?assertEqual(true, recording(Key, Value))
end).

recording_missing_and_mismatched_values_fail_test() -> with_recording_folder(fun(Folder) ->
    Key = <<"example.tables/first label">>,
    Path = filename:join(Folder, binary_to_list(Key)),
    ?assertError({lawspec, <<"no recording recorded/example.tables/first label; run lawspec test --update-recorded to record \"parcel 1\"">>},
        recording(Key, <<"parcel 1">>)),
    ?assertNot(filelib:is_file(Path)),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"\"old\"\n">>),
    ?assertError({lawspec, <<"recorded/example.tables/first label differs: expected \"old\", actual \"parcel 1\" (lawspec test --update-recorded records the new value)">>},
        recording(Key, <<"parcel 1">>)),
    ?assertEqual({ok, <<"\"old\"\n">>}, file:read_file(Path))
end).

recording_update_writes_utf8_and_one_newline_test() -> with_recording_folder(fun(Folder) ->
    Key = <<"example.tables/雪"/utf8>>,
    Path = filename:join(unicode:characters_to_binary(Folder), Key),
    os:putenv("LAWSPEC_UPDATE_RECORDED", "1"),
    ?assertEqual(true, recording(Key, [<<"λ"/utf8>>, 42, true, ls_unit])),
    ?assertEqual({ok, <<"[\"λ\", 42, true, ()]\n"/utf8>>}, file:read_file(Path)),
    ?assertEqual(true, recording(Key, false)),
    ?assertEqual({ok, <<"false\n">>}, file:read_file(Path)),
    os:putenv("LAWSPEC_UPDATE_RECORDED", "0"),
    ?assertEqual(true, recording(Key, false)),
    ?assertException(error, {lawspec, _}, recording(Key, true))
end).

recording_preserves_additional_trailing_newlines_test() -> with_recording_folder(fun(Folder) ->
    Path = filename:join(Folder, "example.tables/value"),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"42\n\n">>),
    ?assertException(error, {lawspec, _}, recording(<<"example.tables/value">>, 42)),
    ok = file:write_file(Path, <<"42\r\n">>),
    ?assertException(error, {lawspec, _}, recording(<<"example.tables/value">>, 42))
end).

recording_io_errors_are_failures_test() -> with_recording_folder(fun(Folder) ->
    Path = filename:join(Folder, "example.tables/value"),
    ok = filelib:ensure_dir(filename:join(Path, "inside")),
    ?assertException(error, {lawspec, _}, recording(<<"example.tables/value">>, 42)),
    os:putenv("LAWSPEC_UPDATE_RECORDED", "1"),
    ?assertException(error, {lawspec, _}, recording(<<"example.tables/value">>, 42))
end).

recording_finds_nearest_project_and_honors_override_test() -> with_recording_folder(fun(Folder) ->
    {ok, PreviousCwd} = file:get_cwd(),
    Child = filename:join([Folder, "application", "subdirectory"]),
    ok = filelib:ensure_dir(filename:join(Child, "unused")),
    ok = file:write_file(filename:join(Folder, "lawspec.json"), <<"{}">>),
    os:unsetenv("LAWSPEC_RECORDED"),
    os:putenv("LAWSPEC_UPDATE_RECORDED", "1"),
    try
        ok = file:set_cwd(Child),
        ?assertEqual(true, recording(<<"example.tables/value">>, 1)),
        ?assertEqual({ok, <<"1\n">>}, file:read_file(filename:join([Folder, "recorded", "example.tables", "value"]))),
        ok = file:make_dir(filename:join(Child, "recorded")),
        ?assertEqual(true, recording(<<"example.tables/value">>, 2)),
        ?assertEqual({ok, <<"2\n">>}, file:read_file("recorded/example.tables/value")),
        os:putenv("LAWSPEC_RECORDED", filename:join(Folder, "override")),
        ?assertEqual(true, recording(<<"example.tables/value">>, 3)),
        ?assertEqual({ok, <<"3\n">>}, file:read_file(filename:join([Folder, "override", "example.tables", "value"])))
    after ok = file:set_cwd(PreviousCwd) end
end).

recording(Key, Value) -> lawspec_beam_runtime:helper(<<"recorded">>, [Key, Value], [], 64).

%% The generated helper carries type information even when a value has the
%% same native representation as Text or Integer. ref:REQ-law-primitives
typed_recording_vectors_read_update_and_reject_changes_test() -> with_recording_folder(fun(Folder) ->
    {ok, Bytes} = file:read_file("test/fixtures/recorded-values.json"),
    lists:foreach(fun(#{<<"name">> := Name, <<"scalar">> := Scalar, <<"text">> := Expected} = Row) ->
        Key = <<"vectors/", Name/binary>>,
        Path = filename:join(unicode:characters_to_binary(Folder), Key),
        Value = lawspec_beam_scalar:literal(Scalar),
        Type = maps:get(<<"type">>, Row, maps:get(<<"type">>, Scalar)),
        Run = fun() -> lawspec_beam_runtime:helper(<<"recorded">>, [Key, Value], [<<"Text">>, Type], 64) end,
        os:putenv("LAWSPEC_UPDATE_RECORDED", "1"),
        ?assertEqual(true, Run()),
        ?assertEqual({ok, <<Expected/binary, "\n">>}, file:read_file(Path)),
        os:unsetenv("LAWSPEC_UPDATE_RECORDED"),
        ?assertEqual(true, Run()),
        ok = file:write_file(Path, <<"stale\n">>),
        ?assertException(error, {lawspec, _}, Run()),
        ?assertEqual({ok, <<"stale\n">>}, file:read_file(Path))
    end, json:decode(Bytes))
end).

with_recording_folder(Body) ->
    Folder = filename:absname(filename:join(".artifacts", "beam recorded 雪 " ++
        integer_to_list(erlang:unique_integer([positive, monotonic])))),
    ok = filelib:ensure_dir(filename:join(Folder, "unused")),
    Keys = ["LAWSPEC_RECORDED", "LAWSPEC_UPDATE_RECORDED"],
    Previous = [{Key, os:getenv(Key)} || Key <- Keys],
    os:putenv("LAWSPEC_RECORDED", Folder),
    os:unsetenv("LAWSPEC_UPDATE_RECORDED"),
    try Body(Folder) after
        lists:foreach(fun({Key, false}) -> os:unsetenv(Key); ({Key, Value}) -> os:putenv(Key, Value) end, Previous),
        ok = file:del_dir_r(Folder)
    end.
