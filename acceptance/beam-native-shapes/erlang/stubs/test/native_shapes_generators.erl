%% User-owned LawSpec adapter. Implement these functions.
-module(native_shapes_generators).
-export([boxes/1, small_int/0, stamps/0]).

-spec boxes(proper_types:raw_type()) -> proper_types:raw_type().

boxes(_Child0) ->
    erlang:error({not_implemented, <<"Implement generator for native.shapes::type::Box"/utf8>>}).

-spec small_int() -> proper_types:raw_type().

small_int() -> erlang:error({not_implemented, <<"Implement generator for Int8"/utf8>>}).

-spec stamps() -> proper_types:raw_type().

stamps() ->
    erlang:error({not_implemented, <<"Implement generator for native.shapes::type::Stamp"/utf8>>}).
