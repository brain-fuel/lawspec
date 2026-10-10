%% Native OTP collections. A server serializes each operation; its creating
%% process owns its lifetime. Async callers share the same public ETS registry.
%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(beam_collections).
-behaviour(gen_server).
-export([new/1, offer/2, poll/1, poll_gleam/1, size/1, add/2, remove/2,
    contains/2, put/3, put_gleam/3, get/2, get_gleam/2, evict/2, evict_gleam/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

new(Kind) ->
    case ets:whereis(?MODULE) of
        undefined -> ets:new(?MODULE,[named_table,public,set]);
        _ -> ok
    end,
    {ok,Pid}=gen_server:start(?MODULE,{self(),Kind},[]),
    Id=ets:update_counter(?MODULE,next_id,{2,1},{next_id,0}),
    true=ets:insert(?MODULE,{Id,Pid}), Id.
request(Id,Operation) -> gen_server:call(ets:lookup_element(?MODULE,Id,2),Operation).
offer(Id,Value) -> request(Id,{offer,Value}).
poll(Id) -> request(Id,poll).
size(Id) -> request(Id,size).
add(Id,Value) -> request(Id,{add,Value}).
remove(Id,Value) -> request(Id,{remove,Value}).
contains(Id,Value) -> request(Id,{contains,Value}).
put(Id,Key,Value) -> request(Id,{put,Key,Value}).
get(Id,Key) -> request(Id,{get,Key}).
evict(Id,Key) -> request(Id,{evict,Key}).
poll_gleam(Id) -> gleam_option(poll(Id)).
put_gleam(Id,Key,Value) -> gleam_option(put(Id,Key,Value)).
get_gleam(Id,Key) -> gleam_option(get(Id,Key)).
evict_gleam(Id,Key) -> gleam_option(evict(Id,Key)).
gleam_option(nothing) -> none;
gleam_option({just,Value}) -> {some,Value}.
map_option(error) -> nothing;
map_option({ok,Value}) -> {just,Value}.

init({Owner,Kind}) ->
    Value=case Kind of 0 -> queue:new(); 1 -> sets:new(); 2 -> #{} end,
    {ok,#{owner=>monitor(process,Owner),value=>Value}}.
handle_call({offer,Item},_,State=#{value:=Value}) ->
    {reply,true,State#{value:=queue:in(Item,Value)}};
handle_call(poll,_,State=#{value:=Value}) ->
    case queue:out(Value) of
        {empty,_} -> {reply,nothing,State};
        {{value,Item},Rest} -> {reply,{just,Item},State#{value:=Rest}}
    end;
handle_call(peek,_,State=#{value:=Value}) ->
    {reply,case queue:peek(Value) of empty -> nothing; {value,Item} -> {just,Item} end,State};
handle_call(size,_,State=#{value:=Value}) -> {reply,queue:len(Value),State};
handle_call({add,Item},_,State=#{value:=Value}) ->
    Added=not sets:is_element(Item,Value),
    {reply,Added,State#{value:=sets:add_element(Item,Value)}};
handle_call({remove,Item},_,State=#{value:=Value}) ->
    {reply,sets:is_element(Item,Value),State#{value:=sets:del_element(Item,Value)}};
handle_call({contains,Item},_,State=#{value:=Value}) -> {reply,sets:is_element(Item,Value),State};
handle_call({put,Key,Item},_,State=#{value:=Value}) ->
    Previous=map_option(maps:find(Key,Value)),
    {reply,Previous,State#{value:=maps:put(Key,Item,Value)}};
handle_call({get,Key},_,State=#{value:=Value}) -> {reply,map_option(maps:find(Key,Value)),State};
handle_call({evict,Key},_,State=#{value:=Value}) ->
    {reply,map_option(maps:find(Key,Value)),State#{value:=maps:remove(Key,Value)}}.
handle_cast(_,State) -> {noreply,State}.
handle_info({'DOWN',Monitor,process,_,_},State=#{owner:=Monitor}) -> {stop,normal,State}.
