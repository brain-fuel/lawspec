%% The Gleam composition adapter's Store: an ETS table of each log's records.
-module(composition_store).
-export([open/0, close/1, records/2, put/3]).

open() -> ets:new(composition_store, [set, public]).

close(Store) ->
    ets:delete(Store),
    nil.

records(Store, Log) ->
    case ets:lookup(Store, Log) of
        [] -> none;
        [{_, Records}] -> {some, Records}
    end.

put(Store, Log, Records) ->
    ets:insert(Store, {Log, Records}),
    nil.
