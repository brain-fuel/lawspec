%% Private state belongs to the callback owner; laws use its PID as a handle.
%% ref:REQ-law-primitives ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_example_resources).
-export([open_store/1,close_store/1,clear_store/1,put/3,get/2,get_gleam/2,is_open/1,size/1,
    write_note/2,read_note/1,read_note_gleam/1,can_listen/1,set_greeting/1,greeting/1,greeting_gleam/1,
    open_pool/1,drain_pool/1,close_pool/1,fill/2,level/1]).
open_store(_) ->
    Table = ets:new(example_store, [private]),
    erlang:put(example_store, Table), self().
close_store(Owner) ->
    Owner = self(), Table = erlang:get(example_store),
    true = ets:delete(Table),
    case ets:info(Table) of undefined -> ok; _ -> error(store_was_not_closed) end.
clear_store(Owner) -> Owner = self(), true = ets:delete_all_objects(erlang:get(example_store)), ok.
put(Owner, Key, Value) ->
    lawspec_beam_resource:call(Owner, fun() -> true = ets:insert(erlang:get(example_store), {Key, Value}), ok end).
get(Owner, Key) -> lawspec_beam_resource:call(Owner, fun() ->
    case ets:lookup(erlang:get(example_store), Key) of [] -> nothing; [{_, Value}] -> {just, Value} end
end).
is_open(Owner) -> is_process_alive(Owner).
size(Owner) -> lawspec_beam_resource:call(Owner, fun() -> ets:info(erlang:get(example_store), size) end).
write_note(Path, Value) -> file:write_file(filename:join(Path, <<"note">>), integer_to_binary(Value)).
read_note(Path) -> case file:read_file(filename:join(Path, <<"note">>)) of
    {error, enoent} -> nothing; {ok, Value} -> {just, binary_to_integer(Value)}
end.
can_listen(Port) ->
    {ok, Socket} = gen_tcp:listen(Port, [{ip, {127,0,0,1}}, {active, false}]),
    ok = gen_tcp:close(Socket), true.
set_greeting(Value) -> true = os:putenv("LAWSPEC_EXAMPLE_GREETING", integer_to_list(Value)), ok.
greeting(_) -> case os:getenv("LAWSPEC_EXAMPLE_GREETING") of false -> nothing; Value -> {just, list_to_integer(Value)} end.
open_pool(_) ->
    case persistent_term:get({?MODULE, pool_opened}, false) of
        false -> persistent_term:put({?MODULE, pool_opened}, true);
        true -> error(<<"a pool starts each case empty: pool must be shared">>)
    end,
    erlang:put(example_level, 0), self().
drain_pool(Owner) -> Owner = self(), erlang:put(example_level, 0), ok.
close_pool(Owner) -> Owner = self(), erlang:erase(example_level), ok.
fill(Owner, Value) -> lawspec_beam_resource:call(Owner, fun() ->
    erlang:put(example_level, erlang:get(example_level) + Value), ok
end).
level(Owner) -> lawspec_beam_resource:call(Owner, fun() -> erlang:get(example_level) end).
get_gleam(Owner, Key) -> optional(get(Owner, Key)).
read_note_gleam(Path) -> optional(read_note(Path)).
greeting_gleam(Value) -> optional(greeting(Value)).
optional(nothing) -> none;
optional({just, Value}) -> {some, Value}.
