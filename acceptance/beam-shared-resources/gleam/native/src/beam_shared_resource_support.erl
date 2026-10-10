%% Native callback ownership and lifecycle evidence, shared by all BEAM targets.
%% ref:REQ-law-primitives ref:REQ-harness-units
-module(beam_shared_resource_support).
-export([open_store/1, reset_store/2, close_store/2, use_store/2, store_value/1,
    open_group/1, reset_group/1, close_group/1, use_group/1,
    open_pool/1, reset_pool/1, close_pool/1, use_pool/1]).

open_store(Tick) -> 1 = Tick, open(store, Tick).
reset_store(Store, Tick) -> reset(Store, Tick).
close_store(Store, Tick) -> close(Store, Tick).
use_store(Store, Value) -> use(Store, Value).
store_value(Store) -> ets:lookup_element(Store, value, 2).
open_group(_) -> open(group, 0).
reset_group(Store) -> reset(Store, 0).
close_group(Store) -> close(Store, 0).
use_group(Store) -> use(Store, 1).
open_pool(_) -> open(run, 0).
reset_pool(Pool) -> reset(Pool, 0).
close_pool(Pool) -> close(Pool, 0).
use_pool(Pool) -> use(Pool, 1).

open(Kind, Tick) ->
    Store = ets:new(?MODULE, [set, public]),
    Id = erlang:unique_integer([positive, monotonic]),
    true = ets:insert(Store, [{meta, Kind, Id, self(), Tick}, {used, false}, {value, 0}]),
    audit(open, Kind, Id, Tick),
    Store.

reset(Store, Tick) ->
    {Kind, Id} = callback(Store, Tick),
    true = ets:insert(Store, [{used, false}, {value, 0}]),
    audit(reset, Kind, Id, Tick),
    ok.

close(Store, Tick) ->
    {Kind, Id} = callback(Store, Tick),
    audit(close, Kind, Id, Tick),
    true = ets:delete(Store),
    ok.

callback(Store, Tick) ->
    [{meta, Kind, Id, Owner, Previous}] = ets:lookup(Store, meta),
    Owner = self(),
    case Kind of store -> true = Tick =:= Previous + 1; _ -> 0 = Tick end,
    true = ets:insert(Store, {meta, Kind, Id, Owner, Tick}),
    {Kind, Id}.

use(Store, Value) ->
    [{meta, _, _, Owner, _}] = ets:lookup(Store, meta),
    Fresh = not ets:lookup_element(Store, used, 2),
    true = ets:insert(Store, [{used, true}, {value, Value}]),
    %% The shared callback process lives beyond the case using its handle.
    Fresh andalso Owner =/= self() andalso is_process_alive(Owner).

audit(Event, Kind, Id, Tick) ->
    case os:getenv("LAWSPEC_RESOURCE_AUDIT") of
        false -> ok;
        Path -> file:write_file(Path, io_lib:format("~s ~s ~B ~B~n",
            [atom_to_list(Event), atom_to_list(Kind), Id, Tick]), [append])
    end.
