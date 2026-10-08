-module(native_token_ffi).
-export([new/0, touch/1, value/2]).

new() -> Ref = make_ref(), put(Ref, 0), Ref.
touch(Ref) -> put(Ref, 1), <<"deliberately non-unit">>.
value(Ref, N) -> N + get(Ref).
