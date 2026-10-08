%% ref:DEC-acceptance-with-mutants
-module(example_orders).
-export([price/1, stock/1, quote/1]).
price(Sku) -> price_of(Sku).
stock(Sku) -> length(unicode:characters_to_list(Sku)).
quote(Sku) -> price_of(Sku).
price_of(<<"free">>) -> 0;
price_of(Sku) -> length(unicode:characters_to_list(Sku)) rem 100.
