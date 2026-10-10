%% @doc Native resource adapter used by all three BEAM acceptance projects.
%% Private ETS state stays in the resource owner; borrowers use messages.
%% ref:REQ-law-primitives ref:DEC-tests-cite-requirements
-module(beam_resource_support).
-export([open_store/1, close_store/1, size/1, write/2, is_open/1,
    directory_empty/1, write_note/2, note_matches/2, file_empty/1,
    set_greeting/1, greeting_matches/1, greeting_absent/1,
    begin_probe/1, end_probe/0, events/0]).

begin_probe(Mode) ->
    _ = ets:new(beam_resource_events, [named_table, public, ordered_set]),
    persistent_term:put({?MODULE, mode}, Mode), ok.
end_probe() ->
    persistent_term:erase({?MODULE, mode}),
    ets:delete(beam_resource_events), ok.
events() -> [Event || {_, Event} <- ets:tab2list(beam_resource_events)].
event(Event) ->
    case ets:whereis(beam_resource_events) of
        undefined -> ok;
        _ -> true = ets:insert(beam_resource_events, {erlang:unique_integer([monotonic]), Event}), ok
    end.
mode() -> persistent_term:get({?MODULE, mode}, normal).
stack() -> case get({?MODULE, stores}) of undefined -> []; Stores -> Stores end.

open_store(_) ->
    Stores = stack(),
    Open = [T || T <- ets:all(), ets:info(T, owner) =:= self(),
        ets:info(T, name) =:= beam_resource_store],
    case length(Stores) < 2 andalso length(Open) < 2 of
        true -> ok;
        false -> error(resource_not_released)
    end,
    case {mode(), ets:whereis(beam_resource_events)} of
        {acquire_failure, Events} when Events =/= undefined ->
            case [V || {opened, _, V} <- events()] of [] -> ok; _ -> error(resource_acquisition_failed) end;
        _ -> ok
    end,
    Store = ets:new(beam_resource_store, [private]),
    put({?MODULE, stores}, [Store | Stores]),
    event({opened, self(), Store}), self().

close_store(Owner) ->
    Owner = self(),
    [Store | Rest] = stack(),
    true = ets:delete(Store),
    case ets:info(Store) of undefined -> ok; _ -> error(resource_not_released) end,
    put({?MODULE, stores}, Rest),
    event({closed, self(), Store}),
    case mode() of release_failure -> error(resource_release_failed); _ -> ok end.

size(Owner) -> lawspec_beam_resource:call(Owner, fun() -> ets:info(hd(stack()), size) end).
is_open(Owner) -> lawspec_beam_resource:call(Owner, fun() -> ets:info(hd(stack())) =/= undefined end).
write(Owner, Number) -> lawspec_beam_resource:call(Owner, fun() ->
    Store = hd(stack()),
    true = ets:insert(Store, {note, Number}),
    event({attempt, Number}),
    case mode() of
        body_failure -> error(resource_body_failed);
        reject -> abs(Number) < 8;
        _ -> true
    end
end).

directory_empty(Path) -> event({directory, Path}), file:list_dir(Path) =:= {ok, []}.
write_note(Path, Number) -> file:write_file(filename:join(Path, <<"note">>), integer_to_binary(Number)) =:= ok.
note_matches(Path, Number) -> file:read_file(filename:join(Path, <<"note">>)) =:= {ok, integer_to_binary(Number)}.
file_empty(Path) -> event({file, Path}), file:read_file(Path) =:= {ok, <<>>}.
set_greeting(Number) -> os:putenv("LAWSPEC_BEAM_RESOURCE_GREETING", integer_to_list(Number)).
greeting_matches(Number) -> os:getenv("LAWSPEC_BEAM_RESOURCE_GREETING") =:= integer_to_list(Number).
greeting_absent(_) -> os:getenv("LAWSPEC_BEAM_RESOURCE_GREETING") =:= false.
