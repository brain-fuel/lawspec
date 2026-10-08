-module(builtins_ffi).
-export([listen_on/1, next_reading/1]).

listen_on(Port) ->
    {ok, Socket} = gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}, {active, false}]),
    gen_tcp:close(Socket),
    true.

next_reading(Cell) -> lawspec_beam_handler:call(Cell, fun(N) -> {N + 1, N + 1} end).
