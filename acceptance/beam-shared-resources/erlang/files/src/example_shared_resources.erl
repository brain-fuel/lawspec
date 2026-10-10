%% ref:REQ-law-primitives ref:REQ-harness-units
-module(example_shared_resources).
-export([open_store/1, reset_store/2, close_store/2, use_store/2, store_value/1,
    open_group/1, reset_group/1, close_group/1, use_group/1,
    open_pool/1, reset_pool/1, close_pool/1, use_pool/1, audit_handler/0]).

open_store(Tick) -> beam_shared_resource_support:open_store(Tick).
reset_store(Store, Tick) -> beam_shared_resource_support:reset_store(Store, Tick).
close_store(Store, Tick) -> beam_shared_resource_support:close_store(Store, Tick).
use_store(Store, Value) -> beam_shared_resource_support:use_store(Store, Value).
store_value(Store) -> beam_shared_resource_support:store_value(Store).
open_group(Unit) -> beam_shared_resource_support:open_group(Unit).
reset_group(Store) -> beam_shared_resource_support:reset_group(Store).
close_group(Store) -> beam_shared_resource_support:close_group(Store).
use_group(Store) -> beam_shared_resource_support:use_group(Store).
open_pool(Unit) -> beam_shared_resource_support:open_pool(Unit).
reset_pool(Pool) -> beam_shared_resource_support:reset_pool(Pool).
close_pool(Pool) -> beam_shared_resource_support:close_pool(Pool).
use_pool(Pool) -> beam_shared_resource_support:use_pool(Pool).

audit_handler() ->
    Count = lawspec_beam_effects:native_cell(0),
    #{tick => fun(_) -> lawspec_beam_effects:native_write(Count,
        lawspec_beam_effects:native_read(Count) + 1) end}.
