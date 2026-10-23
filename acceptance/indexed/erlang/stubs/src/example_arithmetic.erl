%% User-owned LawSpec adapter. Implement these functions.
-module(example_arithmetic).
-export([mirror/1, area/1, duplicate/1, count_pairs/1, drop_first/1]).

-spec mirror(lawspec_data:perfect()) -> lawspec_data:perfect().

mirror(_Perfect) -> erlang:error({not_implemented, <<"example.arithmetic::mirror">>}).

-spec area(lawspec_data:grid()) -> integer().

area(_Grid) -> erlang:error({not_implemented, <<"example.arithmetic::area">>}).

-spec duplicate(lawspec_data:row()) -> lawspec_data:halves().

duplicate(_Row) -> erlang:error({not_implemented, <<"example.arithmetic::duplicate">>}).

-spec count_pairs(lawspec_data:row()) -> lawspec_data:pairs().

count_pairs(_Row) -> erlang:error({not_implemented, <<"example.arithmetic::countPairs">>}).

-spec drop_first(lawspec_data:row()) -> lawspec_data:rest().

drop_first(_Row) -> erlang:error({not_implemented, <<"example.arithmetic::dropFirst">>}).
