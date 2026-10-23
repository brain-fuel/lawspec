%% User-owned LawSpec adapter. Implement these functions.
-module(example_orders).
-export([price/1, stock/1, quote/1]).

-spec price(binary()) -> -2147483648..2147483647.

price(_Text) -> erlang:error({not_implemented, <<"example.orders::price">>}).

-spec stock(binary()) -> -2147483648..2147483647.

stock(_Text) -> erlang:error({not_implemented, <<"example.orders::stock">>}).

-spec quote(binary()) -> -2147483648..2147483647.

quote(_Text) -> erlang:error({not_implemented, <<"example.orders::quote">>}).
