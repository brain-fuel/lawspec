%% User-owned LawSpec adapter. Implement these functions.
-module(example_orders).
-export([price/1, stock/1, quote/1]).

-spec price(binary()) -> -2147483648..2147483647.

price(_Argument0) -> erlang:error({not_implemented, <<"example.orders::price"/utf8>>}).

-spec stock(binary()) -> -2147483648..2147483647.

stock(_Argument0) -> erlang:error({not_implemented, <<"example.orders::stock"/utf8>>}).

-spec quote(binary()) -> -2147483648..2147483647.

quote(_Argument0) -> erlang:error({not_implemented, <<"example.orders::quote"/utf8>>}).
