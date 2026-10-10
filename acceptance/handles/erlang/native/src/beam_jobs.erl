%% A process is the opaque queue handle; ownership stays with the creator.
%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(beam_jobs).
-behaviour(gen_server).
-export([new/0,submit/2,take/1,take_gleam/1,pending/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
new() -> {ok,Pid}=gen_server:start(?MODULE,self(),[]), Pid.
submit(Pid,Value) -> gen_server:call(Pid,{submit,Value}).
take(Pid) -> gen_server:call(Pid,take).
take_gleam(Pid) -> case take(Pid) of nothing -> none; {just,Value} -> {some,Value} end.
pending(Pid) -> gen_server:call(Pid,pending).
init(Owner) -> {ok,#{owner=>monitor(process,Owner),items=>queue:new()}}.
handle_call({submit,Value},_,State=#{items:=Items}) ->
    {reply,true,State#{items:=queue:in(Value,Items)}};
handle_call(take,_,State=#{items:=Items}) ->
    case queue:out(Items) of
        {empty,_} -> {reply,nothing,State};
        {{value,Value},Rest} -> {reply,{just,Value},State#{items:=Rest}}
    end;
handle_call(peek,_,State=#{items:=Items}) ->
    {reply,case queue:peek(Items) of empty -> nothing; {value,Value} -> {just,Value} end,State};
handle_call(pending,_,State=#{items:=Items}) -> {reply,queue:len(Items),State}.
handle_cast(_,State) -> {noreply,State}.
handle_info({'DOWN',Monitor,process,_,_},State=#{owner:=Monitor}) -> {stop,normal,State}.
