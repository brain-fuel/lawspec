%% ref:DEC-acceptance-with-mutants ref:DEC-async-native-tasks
-module(warehouse_native_ffi).
-export([price_of/1, quote_of/1, new/0, restock/2, count/1]).
price_of(Sku) -> erlang:yield(), quote_of(Sku).
quote_of(<<"free">>) -> 0;
quote_of(Sku) -> length(unicode:characters_to_list(Sku)) rem 100.
new() -> atomics:new(1, []).
restock(Shelf, Amount) -> erlang:yield(), atomics:add(Shelf, 1, Amount), nil.
count(Shelf) -> erlang:yield(), atomics:get(Shelf, 1).
