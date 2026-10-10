%% Each caller updates its own replica. Replies can be stale while the final
%% total contains every update, as required by eventual consistency.
%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(beam_views).
-export([new/0,hit/1,total/1]).
new() ->
    case ets:whereis(?MODULE) of
        undefined -> ets:new(?MODULE,[named_table,public,set]);
        _ -> ok
    end,
    ets:update_counter(?MODULE,next_id,{2,1},{next_id,0}).
hit(Id) -> ets:update_counter(?MODULE,{Id,self()},{2,1},{{Id,self()},0}).
total(Id) -> lists:sum([Count || {{Owner,_},Count} <- ets:tab2list(?MODULE),Owner=:=Id]).
