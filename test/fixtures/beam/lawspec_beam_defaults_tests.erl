%% @doc Native built-in services and their scope and scalar boundaries.
%% ref:DEC-tests-cite-requirements ref:DEC-typed-core-boundary
-module(lawspec_beam_defaults_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-export([log/2]).

handler(Unit, Name) -> lawspec_beam_defaults:handler(<<"lawspec.", Unit/binary, "::ability::", Name/binary>>).
call(H, Op, Args) -> lawspec_beam_effects:invoke(H, #{}, Op, Args).
field({ls_data, _, [Value]}) -> Value.
scope(Body) -> lawspec_beam_effects:with_scope(#{}, #{}, fun(_) -> Body() end).

clock_is_monotonic_and_sleep_honours_microseconds_test() ->
    Clock = handler(<<"time">>, <<"Clock">>),
    Times = [field(call(Clock, <<"now">>, [])) || _ <- lists:seq(1, 1000)],
    ?assertEqual(Times, lists:sort(Times)),
    ?assert(hd(Times) > 0 andalso lists:last(Times) =< 9223372036854775807),
    lists:foreach(fun(Micros) ->
        Start = field(call(Clock, <<"now">>, [])),
        ?assertEqual(ls_unit, call(Clock, <<"sleep">>, [{ls_data, <<"lawspec.time::type::Duration::Duration">>, [Micros]}])),
        ?assert(field(call(Clock, <<"now">>, [])) - Start >= Micros)
    end, [0, 1, 999, 1001, 2000]).

random_draws_advance_twice_even_for_invalid_bounds_test() ->
    Saved = os:getenv("LAWSPEC_SEED"),
    try
        lists:foreach(fun(Seed) ->
            true = os:putenv("LAWSPEC_SEED", integer_to_list(Seed)),
            scope(fun() ->
                Random = handler(<<"randomness">>, <<"Random">>),
                lists:foldl(fun(Bound, State) ->
                    {Expected, Next} = reference(State, Bound),
                    ?assertEqual(Expected, call(Random, <<"randomBelow">>, [Bound])), Next
                end, Seed band 16#FFFFFFFFFFFFFFFF, [6, 0, -1, 1, 1000, 9223372036854775807])
            end)
        end, [0, 42, -1, 18446744073709551616])
    after restore_variable("LAWSPEC_SEED", Saved) end.

reference(State, Bound) ->
    Modulus = 18446744073709551616,
    First = (6364136223846793005 * State + 1442695040888963407) rem Modulus,
    Next = (6364136223846793005 * First + 1442695040888963407) rem Modulus,
    Bits = (First div 4294967296) * 4294967296 + (Next div 4294967296),
    {case Bound > 0 of true -> Bits rem Bound; false -> 0 end, Next}.

random_shared_state_is_atomic_and_scope_owned_test() ->
    Leaked = scope(fun() ->
        Sequential = handler(<<"randomness">>, <<"Random">>),
        Parallel = handler(<<"randomness">>, <<"Random">>),
        Draw = fun(H) -> call(H, <<"randomBelow">>, [9223372036854775807]) end,
        Expected = lists:sort([Draw(Sequential) || _ <- lists:seq(1, 100)]),
        Actual = lists:sort(lawspec_beam_runtime:concurrently([fun() -> Draw(Parallel) end || _ <- lists:seq(1, 100)])),
        ?assertEqual(Expected, Actual),
        Parallel
    end),
    ?assertException(exit, {noproc, _}, call(Leaked, <<"randomBelow">>, [10])),
    ?assertError({lawspec, missing_handler_scope}, handler(<<"randomness">>, <<"Random">>)).

secure_random_has_separate_operations_and_valid_bounds_test() ->
    Secure = handler(<<"randomness">>, <<"SecureRandom">>),
    lists:foreach(fun(N) ->
        ?assertEqual(max(0, N), byte_size(call(Secure, <<"secureBytes">>, [N])))
    end, [-1, 0, 1, 32, 4096]),
    lists:foreach(fun(N) ->
        lists:foreach(fun(_) ->
            R = call(Secure, <<"secureBelow">>, [N]),
            ?assert(case N > 0 of true -> R >= 0 andalso R < N; false -> R =:= 0 end)
        end, lists:seq(1, 100))
    end, [-1, 0, 1, 3, 9223372036854775807]),
    Token = call(Secure, <<"secureToken">>, []),
    ?assertEqual(64, byte_size(Token)),
    ?assert(lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, binary_to_list(Token))),
    ?assertNotEqual(call(Secure, <<"secureBytes">>, [32]), call(Secure, <<"secureBytes">>, [32])),
    ?assertError({lawspec, {missing_handler_operation, <<"randomBelow">>}}, call(Secure, <<"randomBelow">>, [10])).

filesystem_uses_bytes_and_does_not_follow_removed_symlinks_test() ->
    Files = handler(<<"host">>, <<"FileSystem">>),
    Directory = call(Files, <<"temporaryDirectory">>, [<<"lawspec-default-">>]),
    Outside = call(Files, <<"temporaryFile">>, [<<"lawspec-outside-">>]),
    try
        {ok, DirectoryInfo} = file:read_file_info(Directory),
        ?assertEqual(8#700, DirectoryInfo#file_info.mode band 8#777),
        Path = filename:join(Directory, <<"unicode-", 16#1F407/utf8>>),
        Bytes = <<0, 255, 254, 128>>,
        ?assertEqual(ls_unit, call(Files, <<"writeBytes">>, [Path, Bytes])),
        ?assertEqual(Bytes, field(call(Files, <<"readBytes">>, [Path]))),
        ?assertEqual(true, call(Files, <<"pathExists">>, [Path])),
        Link = filename:join(Directory, <<"link">>),
        case file:make_symlink(Outside, Link) of
            ok -> ?assertEqual(true, call(Files, <<"pathExists">>, [Link]));
            {error, enotsup} -> ok
        end,
        ?assertEqual(ls_unit, call(Files, <<"removePath">>, [Directory])),
        ?assertEqual(true, call(Files, <<"pathExists">>, [Outside])),
        ?assertEqual(ls_unit, call(Files, <<"removePath">>, [Directory])),
        ?assertEqual({ls_data, <<"Maybe::Nothing">>, []}, call(Files, <<"readBytes">>, [Path])),
        ?assertEqual({ls_data, <<"Maybe::Nothing">>, []}, call(Files, <<"readBytes">>, [<<0>>])),
        ?assertEqual(false, call(Files, <<"pathExists">>, [<<0>>]))
    after
        call(Files, <<"removePath">>, [Directory]),
        call(Files, <<"removePath">>, [Outside])
    end.

temporary_files_are_empty_private_unique_and_keep_the_prefix_test() ->
    Files = handler(<<"host">>, <<"FileSystem">>),
    Paths = [call(Files, <<"temporaryFile">>, [<<"lawspec-", 16#E9/utf8, "-">>]) || _ <- lists:seq(1, 20)],
    try
        ?assertEqual(length(Paths), length(lists:usort(Paths))),
        lists:foreach(fun(Path) ->
            ?assertEqual(<<>>, field(call(Files, <<"readBytes">>, [Path]))),
            {ok, Info} = file:read_file_info(Path),
            ?assertEqual(8#600, Info#file_info.mode band 8#777),
            ?assertMatch(<<"lawspec-", 16#C3, 16#A9, "-", _/binary>>, filename:basename(Path))
        end, Paths),
        ?assertError({lawspec, invalid_temporary_prefix}, call(Files, <<"temporaryFile">>, [<<"../bad">>]))
    after lists:foreach(fun(Path) -> call(Files, <<"removePath">>, [Path]) end, Paths) end.

environment_snapshot_restores_changes_without_interpreting_names_test() ->
    Env = handler(<<"host">>, <<"Environment">>),
    Saved = call(Env, <<"environmentSnapshot">>, []),
    Name = "LAWSPEC_DEFAULTS_TEST",
    Added = "LAWSPEC_DEFAULTS_ADDED_TEST",
    try
        true = os:putenv(Name, "before"),
        os:unsetenv(Added),
        Snapshot = call(Env, <<"environmentSnapshot">>, []),
        true = os:putenv(Name, "after"),
        true = os:putenv(Added, "added"),
        ?assertEqual(ls_unit, call(Env, <<"restoreEnvironment">>, [Snapshot])),
        ?assertEqual(<<"before">>, field(call(Env, <<"environmentVariable">>, [list_to_binary(Name)]))),
        ?assertEqual(false, os:getenv(Added)),
        lists:foreach(fun(Invalid) ->
            ?assertEqual({ls_data, <<"Maybe::Nothing">>, []}, call(Env, <<"environmentVariable">>, [Invalid]))
        end, [<<>>, <<"a=b">>, <<"a", 0>>]),
        ?assertError({lawspec, invalid_environment_snapshot}, call(Env, <<"restoreEnvironment">>, [<<"{\"\":\"bad\"}">>])),
        ?assertError({lawspec, invalid_environment_snapshot}, call(Env, <<"restoreEnvironment">>, [<<"[]">>])),
        ?assertEqual("before", os:getenv(Name))
    after call(Env, <<"restoreEnvironment">>, [Saved]) end.

free_port_is_released_before_return_test() ->
    Ports = handler(<<"host">>, <<"Ports">>),
    Port = call(Ports, <<"freePort">>, []),
    ?assert(Port >= 1 andalso Port =< 65535),
    {ok, Socket} = gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}, {active, false}]),
    gen_tcp:close(Socket).

log_and_trace_use_logger_domains_and_literal_messages_test() ->
    #{level := PreviousLevel} = logger:get_primary_config(),
    Ref = make_ref(),
    ok = logger:add_handler(lawspec_defaults_test, ?MODULE, #{config => #{receiver => self(), ref => Ref}}),
    ok = logger:set_primary_config(level, debug),
    try
        Log = handler(<<"logging">>, <<"Log">>),
        Trace = handler(<<"logging">>, <<"Trace">>),
        Message = <<"literal ~p 100%">>,
        lists:foreach(fun({Tag, Level}) ->
            ?assertEqual(ls_unit, call(Log, <<"logMessage">>, [{ls_data, <<"lawspec.logging::type::LogLevel::", Tag/binary>>, []}, Message])),
            receive {Ref, #{level := Actual, msg := {"~ts", [Message]}, meta := #{domain := [lawspec]}}} ->
                ?assertEqual(Level, Actual)
            after 1000 -> error(missing_log) end
        end, [{<<"Debug">>, debug}, {<<"Info">>, info}, {<<"Warning">>, warning}, {<<"Error">>, error}]),
        ?assertEqual(ls_unit, call(Trace, <<"traceEvent">>, [Message])),
        receive {Ref, #{level := debug, meta := #{domain := [lawspec, trace]}}} -> ok
        after 1000 -> error(missing_trace) end
    after
        logger:set_primary_config(level, PreviousLevel),
        logger:remove_handler(lawspec_defaults_test)
    end.

log(Event, #{config := #{receiver := Receiver, ref := Ref}}) -> Receiver ! {Ref, Event}, ok.

pause_returns_unit_test() ->
    ?assertEqual(ls_unit, call(handler(<<"concurrent">>, <<"Async">>), <<"pause">>, [])).

restore_variable(Name, false) -> os:unsetenv(Name);
restore_variable(Name, Value) -> os:putenv(Name, Value).
