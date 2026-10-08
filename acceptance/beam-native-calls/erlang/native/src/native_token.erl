-module(native_token).
-export([new/0, touch/1, value/2]).

new() -> Ref = make_ref(), put(Ref, 0), Ref.
touch(Ref) -> put(Ref, 1), deliberately_non_unit.
value(Ref, N) -> N + get(Ref).
