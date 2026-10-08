-module(crypto_keys_ffi).
-export([increment/1]).
increment(Cell) -> lawspec_beam_handler:call(Cell, fun(N) -> {nil, N + 1} end).
