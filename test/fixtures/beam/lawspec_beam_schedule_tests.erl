%% @doc Native EUnit schedules must replay, overlap and retain real failures.
%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(lawspec_beam_schedule_tests).
-include_lib("eunit/include/eunit.hrl").

order_test() ->
    Previous = os:getenv("LAWSPEC_SEED"),
    try
        Items = lists:seq(1, 20),
        os:putenv("LAWSPEC_SEED", "11"),
        A = lawspec_beam_schedule:order(<<"unit">>, true, Items),
        ?assertEqual(A, lawspec_beam_schedule:order(<<"unit">>, true, Items)),
        ?assertEqual(Items, lists:sort(A)),
        os:putenv("LAWSPEC_SEED", "12"),
        ?assertNotEqual(A, lawspec_beam_schedule:order(<<"unit">>, true, Items)),
        ?assertEqual(Items, lawspec_beam_schedule:order(<<"unit">>, false, Items))
    after restore("LAWSPEC_SEED", Previous) end.

parallel_test() ->
    with_stats(fun(Directory) ->
        Parent = self(),
        %% Each native case needs a second case to enter before proceeding.
        %% Serializing the descriptor makes the native run fail its timeout.
        Barrier = spawn(fun() -> barrier([]) end),
        Test = fun() ->
            Table = ets:new(private_case, [private]),
            ets:insert(Table, {owner, self()}),
            Barrier ! {arrive, self()},
            receive go -> ok after 1000 -> error(no_overlap) end,
            ?assertEqual([{owner, self()}], ets:lookup(Table, owner)),
            ets:delete(Table), Parent ! finished
        end,
        Descriptor = lawspec_beam_schedule:eunit(<<"parallel">>, false, true,
            [{"law", [{"one", Test}, {"two", Test}]}]),
        ?assertEqual(ok, eunit:test(Descriptor)),
        receive finished -> ok after 1000 -> error(missing_case) end,
        receive finished -> ok after 1000 -> error(missing_case) end,
        [Report] = reports(Directory),
        ?assertMatch(#{<<"parallel">> := <<"parallel">>, <<"workers">> := 2}, Report)
    end).

barrier(Peers) -> receive {arrive, Pid} -> case [Pid | Peers] of
    [A, B] -> A ! go, B ! go;
    More -> barrier(More)
end end.

failure_test() ->
    with_stats(fun(Directory) ->
        Descriptor = lawspec_beam_schedule:eunit(<<"failed">>, false, true,
            [{"law", [{"native failure", fun() -> error(original_failure) end}]}]),
        ?assertEqual(error, eunit:test(Descriptor)),
        [Report] = reports(Directory),
        ?assertMatch(#{<<"workers">> := 1}, Report)
    end).

skip_test() ->
    with_stats(fun(Directory) ->
        Cases = lawspec_beam_harness:erlang_cases([{"skip", {skip, <<"skipped">>, <<"reason">>}}]),
        ?assertEqual(ok, eunit:test(lawspec_beam_schedule:eunit(<<"only skips">>, true, true, [{"law", Cases}]))),
        Rows = reports(Directory),
        ?assertEqual(1, length([R || R = #{<<"outcome">> := <<"skipped">>} <- Rows])),
        ?assertEqual(1, length([R || R = #{<<"workers">> := 0} <- Rows]))
    end).

with_stats(Body) ->
    Directory = filename:join(".artifacts/beam-scheduling-runtime", integer_to_list(erlang:unique_integer([positive]))),
    Previous = os:getenv("LAWSPEC_STATS"),
    ok = filelib:ensure_dir(filename:join(Directory, "record.json")),
    os:putenv("LAWSPEC_STATS", Directory),
    try Body(Directory) after restore("LAWSPEC_STATS", Previous), file:del_dir_r(Directory) end.
reports(Directory) -> [json:decode(element(2, file:read_file(Path))) || Path <- filelib:wildcard(filename:join(Directory, "*.json"))].
restore(Name, false) -> os:unsetenv(Name);
restore(Name, Value) -> os:putenv(Name, Value).
