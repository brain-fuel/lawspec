%% An atomic native counter used by asynchronous model adapters. The test
%% process owns the ETS table; its async workers share the public entries.
%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(beam_model_counter).
-export([new/0, increment/1, decrement/1, read/1]).

new() ->
    case ets:whereis(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, public, set]);
        _ -> ok
    end,
    Id = ets:update_counter(?MODULE, next_id, {2, 1}, {next_id, 0}),
    true = ets:insert(?MODULE, {Id, 0}), Id.
increment(Id) -> ets:update_counter(?MODULE, Id, {2, 1}).
decrement(Id) -> ets:update_counter(?MODULE, Id, {2, -1}).
read(Id) -> ets:lookup_element(?MODULE, Id, 2).
