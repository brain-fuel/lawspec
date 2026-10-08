%% Native Erlang adapters used to exercise every scalar bridge.
%% ref:DEC-acceptance-with-mutants
-module(example_scalar_adapters).
-export([echo_char/1, echo_code_point/1, echo_code_unit/1, echo_bytes/1,
    echo_complex/1, successor/1, narrow/1, add_decimal/2, same_symbol/2,
    echo_raw/1, echo_presence/1, finish/1, preserve_big/1, machine_echo/1]).

echo_char(Value) -> Value.
echo_code_point(Value) -> Value.
echo_code_unit(Value) -> Value.
echo_bytes(Value) -> Value.
echo_complex(Value) -> Value.
successor(Value) -> Value + 1.
narrow(Value) -> Value.
add_decimal(A, B) -> lawspec_beam_scalar:binary(<<"+">>, A, B, <<"Decimal">>, <<"Decimal">>).
same_symbol(A, B) -> lawspec_beam_scalar:equal(A, B).
echo_raw(Value) -> Value.
echo_presence(Value) -> Value.
finish(ok) -> ok.
preserve_big(Value) -> Value.
machine_echo(Value) -> Value.
