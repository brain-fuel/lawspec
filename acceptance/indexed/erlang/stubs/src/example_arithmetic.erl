%% User-owned LawSpec adapter. Implement these functions.
-module(example_arithmetic).
-export([mirror/1, area/1, duplicate/1, count_pairs/1, drop_first/1]).

-spec mirror(lawspec_data:perfect()) -> lawspec_data:perfect().

mirror(_Argument0) -> erlang:error({not_implemented, <<"example.arithmetic::mirror"/utf8>>}).

-spec area(lawspec_data:grid()) -> integer().

area(_Argument0) -> erlang:error({not_implemented, <<"example.arithmetic::area"/utf8>>}).

-spec duplicate(lawspec_data:row()) -> lawspec_data:halves().

duplicate(_Argument0) -> erlang:error({not_implemented, <<"example.arithmetic::duplicate"/utf8>>}).

-spec count_pairs(lawspec_data:row()) -> lawspec_data:pairs().

count_pairs(_Argument0) ->
    erlang:error({not_implemented, <<"example.arithmetic::countPairs"/utf8>>}).

-spec drop_first(lawspec_data:row()) -> lawspec_data:rest().

drop_first(_Argument0) -> erlang:error({not_implemented, <<"example.arithmetic::dropFirst"/utf8>>}).
