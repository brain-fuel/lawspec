%% @doc Built-in ability defaults shared by Erlang, Elixir and Gleam.
%% Values here are logical values; generated interfaces check both native
%% crossings. Mutable random state belongs to the caller's handler scope.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_defaults).
-export([handler/1, now_micros/0, sleep_micros/1]).
-on_load(init_clock/0).

init_clock() ->
    Key = {?MODULE, clock_offset},
    persistent_term:put(Key, persistent_term:get(Key, erlang:time_offset(microsecond))),
    ok.

handler(<<"lawspec.crypto::ability::", _/binary>> = Key) -> lawspec_beam_crypto:handler(Key);
handler(<<"lawspec.time::ability::Clock">>) ->
    stateless(#{
        <<"now">> => fun(_, []) ->
            data(<<"lawspec.time::type::Instant::Instant">>, [now_micros()])
        end,
        <<"sleep">> => fun(_, [{ls_data, <<"lawspec.time::type::Duration::Duration">>, [Micros]}]) ->
            sleep_micros(Micros), ls_unit
        end});
handler(<<"lawspec.randomness::ability::Random">>) ->
    Seed = try list_to_integer(os:getenv("LAWSPEC_SEED", "0")) catch error:badarg -> 0 end,
    Cell = lawspec_beam_effects:native_cell(Seed band 16#FFFFFFFFFFFFFFFF),
    stateless(#{<<"randomBelow">> => fun(_, [Bound]) ->
        lawspec_beam_handler:call(Cell, fun(State) ->
            First = random_step(State),
            Second = random_step(First),
            Bits = ((First bsr 32) bsl 32) bor (Second bsr 32),
            Draw = case Bound > 0 of true -> Bits rem Bound; false -> 0 end,
            {Draw, Second}
        end)
    end});
handler(<<"lawspec.randomness::ability::SecureRandom">>) ->
    stateless(#{
        <<"secureBytes">> => fun(_, [Count]) -> crypto:strong_rand_bytes(max(0, Count)) end,
        <<"secureBelow">> => fun(_, [Bound]) -> secure_below(Bound) end,
        <<"secureToken">> => fun(_, []) -> binary:encode_hex(crypto:strong_rand_bytes(32), lowercase) end});
handler(<<"lawspec.host::ability::FileSystem">>) ->
    stateless(#{
        <<"readBytes">> => fun(_, [Path]) -> case file:read_file(Path) of
            {ok, Bytes} -> just(Bytes);
            {error, _} -> nothing()
        end end,
        <<"writeBytes">> => fun(_, [Path, Bytes]) -> file_result(file:write_file(Path, Bytes)) end,
        <<"pathExists">> => fun(_, [Path]) -> case file:read_link_info(Path) of
            {ok, _} -> true;
            {error, _} -> false
        end end,
        <<"removePath">> => fun(_, [Path]) -> case file:del_dir_r(Path) of
            {error, enoent} -> ls_unit;
            Result -> file_result(Result)
        end end,
        <<"temporaryDirectory">> => fun(_, [Prefix]) -> temporary(directory, Prefix, 100) end,
        <<"temporaryFile">> => fun(_, [Prefix]) -> temporary(file, Prefix, 100) end});
handler(<<"lawspec.host::ability::Environment">>) ->
    stateless(#{
        <<"environmentVariable">> => fun(_, [Name]) ->
            case valid_name(Name) of
                false -> nothing();
                true -> case os:getenv(unicode:characters_to_list(Name)) of
                    false -> nothing();
                    Value -> just(unicode:characters_to_binary(Value))
                end
            end
        end,
        <<"environmentSnapshot">> => fun(_, []) ->
            iolist_to_binary(json:encode(maps:from_list([
                {unicode:characters_to_binary(Name), unicode:characters_to_binary(Value)}
                || {Name, Value} <- os:env()])))
        end,
        <<"restoreEnvironment">> => fun(_, [Saved]) -> restore_environment(Saved) end});
handler(<<"lawspec.host::ability::Ports">>) ->
    stateless(#{<<"freePort">> => fun(_, []) ->
        {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {active, false}]),
        try
            {ok, {_, Port}} = inet:sockname(Socket),
            Port
        after gen_tcp:close(Socket) end
    end});
handler(<<"lawspec.logging::ability::Log">>) ->
    stateless(#{<<"logMessage">> => fun(_, [Level, Message]) ->
        logger:log(log_level(Level), "~ts", [Message], #{domain => [lawspec]}), ls_unit
    end});
handler(<<"lawspec.logging::ability::Trace">>) ->
    stateless(#{<<"traceEvent">> => fun(_, [Message]) ->
        logger:debug("~ts", [Message], #{domain => [lawspec, trace]}), ls_unit
    end});
handler(<<"lawspec.concurrent::ability::Async">>) ->
    stateless(#{<<"pause">> => fun(_, []) -> erlang:yield(), ls_unit end});
handler(Ability) -> erlang:error({lawspec, {unknown_default_handler, Ability}}).

stateless(Operations) -> lawspec_beam_effects:stateless(Operations).
data(Tag, Fields) -> {ls_data, Tag, Fields}.
just(Value) -> data(<<"Maybe::Just">>, [Value]).
nothing() -> data(<<"Maybe::Nothing">>, []).

%% Freeze the VM's wall-clock offset when the module loads. Subsequent clock
%% corrections cannot move this clock backwards. Sleep deadlines use monotonic
%% time directly so even a saturated Instant cannot shorten a requested sleep.
now_micros() ->
    min(9223372036854775807, max(0, erlang:monotonic_time(microsecond) +
        persistent_term:get({?MODULE, clock_offset}))).

sleep_micros(Micros) when is_integer(Micros), Micros >= 0 ->
    sleep_until(erlang:monotonic_time(microsecond) + Micros).

sleep_until(Deadline) ->
    case Deadline - erlang:monotonic_time(microsecond) of
        Left when Left > 0 ->
            Millis = min(16#FFFFFFFF, (Left + 999) div 1000),
            receive after Millis -> sleep_until(Deadline) end;
        _ -> ok
    end.

random_step(State) -> (6364136223846793005 * State + 1442695040888963407) band 16#FFFFFFFFFFFFFFFF.

secure_below(Bound) when Bound < 1 -> 0;
secure_below(Bound) ->
    %% Rejection sampling avoids modulo bias for every positive Int64 bound.
    Limit = (1 bsl 64) - ((1 bsl 64) rem Bound),
    <<Draw:64/unsigned-big>> = crypto:strong_rand_bytes(8),
    case Draw < Limit of true -> Draw rem Bound; false -> secure_below(Bound) end.

file_result(ok) -> ls_unit;
file_result({error, Reason}) -> erlang:error({lawspec, {filesystem, Reason}}).

temporary(_, _, 0) -> erlang:error({lawspec, temporary_name_exhausted});
temporary(Kind, Prefix, Attempts) ->
    case binary:match(Prefix, [<<0>>, <<"/">>, <<"\\">>]) of
        nomatch -> ok;
        _ -> erlang:error({lawspec, invalid_temporary_prefix})
    end,
    Name = <<Prefix/binary, (binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))/binary>>,
    Path = filename:join(temporary_root(), Name),
    Created = case Kind of
        directory -> file:make_dir(Path);
        file -> case file:open(Path, [write, binary, exclusive, raw]) of
            {ok, Device} -> file:close(Device);
            Error -> Error
        end
    end,
    case Created of
        {error, eexist} -> temporary(Kind, Prefix, Attempts - 1);
        ok ->
            Mode = case Kind of directory -> 8#700; file -> 8#600 end,
            case file:change_mode(Path, Mode) of
                ok -> Path;
                Error2 -> file:del_dir_r(Path), file_result(Error2)
            end;
        Error3 -> file_result(Error3)
    end.

temporary_root() ->
    Candidates = [unicode:characters_to_binary(P) || Name <- ["TMPDIR", "TMP", "TEMP"],
        P <- [os:getenv(Name)], P =/= false, P =/= ""] ++
        case os:type() of {win32, _} -> [<<".">>]; _ -> [<<"/tmp">>] end,
    case [filename:absname(P) || P <- Candidates, filelib:is_dir(P)] of
        [Root | _] -> Root;
        [] -> erlang:error({lawspec, no_temporary_directory})
    end.

valid_name(Name) when is_binary(Name), byte_size(Name) > 0 ->
    binary:match(Name, [<<0>>, <<"=">>]) =:= nomatch;
valid_name(_) -> false.

restore_environment(Saved) ->
    Decoded = json:decode(Saved),
    %% Validate the entire snapshot before changing any environment variable.
    Valid = is_map(Decoded) andalso lists:all(fun({Name, Value}) ->
        valid_name(Name) andalso is_binary(Value) andalso binary:match(Value, <<0>>) =:= nomatch
    end, maps:to_list(Decoded)),
    case Valid of
        false -> erlang:error({lawspec, invalid_environment_snapshot});
        true ->
            lists:foreach(fun({Name, _}) ->
                case maps:is_key(unicode:characters_to_binary(Name), Decoded) of
                    true -> ok;
                    false -> os:unsetenv(Name)
                end
            end, os:env()),
            maps:foreach(fun(Name, Value) ->
                true = os:putenv(unicode:characters_to_list(Name), unicode:characters_to_list(Value))
            end, Decoded),
            ls_unit
    end.

log_level({ls_data, <<"lawspec.logging::type::LogLevel::Debug">>, []}) -> debug;
log_level({ls_data, <<"lawspec.logging::type::LogLevel::Info">>, []}) -> info;
log_level({ls_data, <<"lawspec.logging::type::LogLevel::Warning">>, []}) -> warning;
log_level({ls_data, <<"lawspec.logging::type::LogLevel::Error">>, []}) -> error.
