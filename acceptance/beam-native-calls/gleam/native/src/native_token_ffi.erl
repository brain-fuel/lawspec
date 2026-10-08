-module(native_token_ffi).
-export([new/0, touch/1, value/2]).

new() -> atomics:new(1, []).
touch(Ref) -> atomics:put(Ref, 1, 1), <<"deliberately non-unit">>.
value(Ref, N) -> N + atomics:get(Ref, 1).
