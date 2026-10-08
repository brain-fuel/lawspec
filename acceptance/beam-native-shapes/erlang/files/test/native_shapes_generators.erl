-module(native_shapes_generators).
-export([boxes/1, small_int/0, stamps/0]).
-include("native_shapes.hrl").
-compile(nowarn_unused_record).

boxes(Child) -> proper_types:bind(Child, fun(V) -> proper_types:exactly(#wrapped{stored = V}) end, false).
small_int() -> proper_types:integer(6, 127).
stamps() -> erlang:error(finite_type_must_not_call_factory).
