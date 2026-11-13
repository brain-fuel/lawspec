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

echo_char(_Char1) -> erlang:error({not_implemented, <<"example.scalar_adapters::echoChar">>}).

-spec echo_code_point(non_neg_integer()) -> non_neg_integer().

echo_code_point(_CodePoint1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoCodePoint">>}).

-spec echo_code_unit(non_neg_integer()) -> non_neg_integer().

echo_code_unit(_CodeUnit16_1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoCodeUnit">>}).

-spec echo_bytes(binary()) -> binary().

echo_bytes(_Bytes1) -> erlang:error({not_implemented, <<"example.scalar_adapters::echoBytes">>}).

-spec echo_complex(lawspec_beam_scalar:complex()) -> lawspec_beam_scalar:complex().

echo_complex(_Complex64_1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoComplex">>}).

-spec successor(-128..127) -> integer().

successor(_Int8_1) -> erlang:error({not_implemented, <<"example.scalar_adapters::successor">>}).

-spec narrow(-128..127) -> -128..127.

narrow(_Int8_1) -> erlang:error({not_implemented, <<"example.scalar_adapters::narrow">>}).

-spec add_decimal(
    lawspec_beam_scalar:decimal(),
    lawspec_beam_scalar:decimal()
) -> lawspec_beam_scalar:decimal().

add_decimal(_Decimal1, _Decimal2) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::addDecimal">>}).

-spec same_symbol(lawspec_beam_scalar:symbol(), lawspec_beam_scalar:symbol()) -> boolean().

same_symbol(_Symbol1, _Symbol2) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::sameSymbol">>}).

-spec echo_raw([non_neg_integer()]) -> [non_neg_integer()].

echo_raw(_Utf16Text1) -> erlang:error({not_implemented, <<"example.scalar_adapters::echoRaw">>}).

-spec echo_presence(
    none | {some, null | {non_null, -128..127}}
) -> none | {some, null | {non_null, -128..127}}.

echo_presence(_Optional1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::echoPresence">>}).

-spec finish(ok) -> ok.

finish(_Unit1) -> erlang:error({not_implemented, <<"example.scalar_adapters::finish">>}).

-spec preserve_big(0..18446744073709551615) -> 0..18446744073709551615.

preserve_big(_Uint64_1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::preserveBig">>}).

-spec machine_echo(
    -9223372036854775808..9223372036854775807
) -> -9223372036854775808..9223372036854775807.

machine_echo(_IntSize1) ->
    erlang:error({not_implemented, <<"example.scalar_adapters::machineEcho">>}).
