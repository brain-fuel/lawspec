%% User-owned LawSpec adapter. Implement these functions.
-module(example_scalar_adapters).
-export([
    echo_char/1,
    echo_code_point/1,
    echo_code_unit/1,
    echo_bytes/1,
    echo_complex/1,
    successor/1,
    narrow/1,
    add_decimal/2,
    same_symbol/2,
    echo_raw/1,
    echo_presence/1,
    finish/1,
    preserve_big/1,
    machine_echo/1
]).

-spec echo_char(non_neg_integer()) -> non_neg_integer().

echo_char(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoChar"/utf8>>}).

-spec echo_code_point(non_neg_integer()) -> non_neg_integer().

echo_code_point(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoCodePoint"/utf8>>}).

-spec echo_code_unit(non_neg_integer()) -> non_neg_integer().

echo_code_unit(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoCodeUnit"/utf8>>}).

-spec echo_bytes(binary()) -> binary().

echo_bytes(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoBytes"/utf8>>}).

-spec echo_complex(lawspec_beam_scalar:complex()) -> lawspec_beam_scalar:complex().

echo_complex(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoComplex"/utf8>>}).

-spec successor(-128..127) -> integer().

successor(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::successor"/utf8>>}).

-spec narrow(-128..127) -> -128..127.

narrow(_Argument0) -> erlang:error({not_implemented, <<"example.scalar_adapters::narrow"/utf8>>}).

-spec add_decimal(lawspec_beam_scalar:decimal(), lawspec_beam_scalar:decimal()) ->
    lawspec_beam_scalar:decimal().

add_decimal(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::addDecimal"/utf8>>}).

-spec same_symbol(lawspec_beam_scalar:symbol(), lawspec_beam_scalar:symbol()) -> boolean().

same_symbol(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::sameSymbol"/utf8>>}).

-spec echo_raw([non_neg_integer()]) -> [non_neg_integer()].

echo_raw(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoRaw"/utf8>>}).

-spec echo_presence(none | {some, null | {non_null, -128..127}}) ->
    none | {some, null | {non_null, -128..127}}.

echo_presence(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoPresence"/utf8>>}).

-spec finish(ok) -> ok.

finish(_Argument0) -> erlang:error({not_implemented, <<"example.scalar_adapters::finish"/utf8>>}).

-spec preserve_big(0..18446744073709551615) -> 0..18446744073709551615.

preserve_big(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::preserveBig"/utf8>>}).

-spec machine_echo(-9223372036854775808..9223372036854775807) ->
    -9223372036854775808..9223372036854775807.

machine_echo(_Argument0) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::machineEcho"/utf8>>}).
