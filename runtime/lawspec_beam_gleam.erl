%% @doc Native Gleam representations and typed scalar facade entry points.
%% ref:DEC-native-bindings-typed-identity ref:DEC-portable-exact-arithmetic
-module(lawspec_beam_gleam).
-export([codecs/0, float32_from_bits/1, float64_from_bits/1, float_bits/1,
    float32_from_native/1, float64_from_native/1, float_to_native/1,
    complex64/2, complex128/2, complex_parts/1, decimal_parts/1,
    scalar_binary/4, scalar_compare/2, symbol_description/1, run_case/2]).

codecs() -> #{
    <<"Unit">> => #{encode => fun(ls_unit, []) -> nil end,
        decode => fun(nil, []) -> ls_unit; (_, _) -> fail(unit) end},
    <<"Maybe">> => #{encode => fun
        ({ls_data, <<"Maybe::Nothing">>, []}, [_]) -> none;
        ({ls_data, <<"Maybe::Just">>, [V]}, [F]) -> {some, F(V)} end,
        decode => fun
            (none, [_]) -> {ls_data, <<"Maybe::Nothing">>, []};
            ({some, V}, [F]) -> {ls_data, <<"Maybe::Just">>, [F(V)]};
            (_, _) -> fail('maybe') end},
    <<"Either">> => #{encode => fun
        ({ls_data, <<"Either::Left">>, [V]}, [F, _]) -> {error, F(V)};
        ({ls_data, <<"Either::Right">>, [V]}, [_, F]) -> {ok, F(V)} end,
        decode => fun
            ({error, V}, [F, _]) -> {ls_data, <<"Either::Left">>, [F(V)]};
            ({ok, V}, [_, F]) -> {ls_data, <<"Either::Right">>, [F(V)]};
            (_, _) -> fail(either) end},
    <<"Optional">> => presence_codec(<<"Optional">>, absent, present),
    <<"Nullable">> => presence_codec(<<"Nullable">>, null_value, non_null)
}.

presence_codec(Name, Empty, Present) -> #{
    encode => fun
        ({ls_presence, N, none}, [_]) when N =:= Name -> Empty;
        ({ls_presence, N, {some, V}}, [F]) when N =:= Name -> {Present, F(V)} end,
    decode => fun
        (E, [_]) when E =:= Empty -> {ls_presence, Name, none};
        ({P, V}, [F]) when P =:= Present -> {ls_presence, Name, {some, F(V)}};
        (_, _) -> fail(Name) end
}.
fail(Type) -> erlang:error({lawspec, {invalid_gleam_value, Type}}).

float32_from_bits(Bits) -> lawspec_beam_scalar:float_bits(32, Bits).
float64_from_bits(Bits) -> lawspec_beam_scalar:float_bits(64, Bits).
float_bits({ls_float, _, Bits}) -> Bits.
float32_from_native(Value) -> lawspec_beam_scalar:float_from_native(32, Value).
float64_from_native(Value) -> lawspec_beam_scalar:float_from_native(64, Value).
float_to_native(Value) ->
    case lawspec_beam_scalar:float_class(Value) of
        nan -> {error, <<"NaN has no native BEAM float representation">>};
        infinity -> {error, <<"Infinity has no native BEAM float representation">>};
        _ -> {ok, lawspec_beam_scalar:float_to_native(Value)}
    end.
complex64(R, I) -> complex(32, R, I).
complex128(R, I) -> complex(64, R, I).
complex(W, {ls_float, W, _} = R, {ls_float, W, _} = I) -> {ls_complex, W, R, I}.
complex_parts({ls_complex, _, R, I}) -> {R, I}.
decimal_parts({ls_decimal, C, E}) -> {C, E}.
scalar_binary(Op, Type, A, B) -> lawspec_beam_scalar:binary(Op, A, B, Type, Type).
scalar_compare(A, B) -> case lawspec_beam_scalar:float_compare(A, B) of
    unordered -> none;
    Value -> {some, Value}
end.
symbol_description({ls_symbol, _, Description}) -> Description.

%% Called by native Gleeunit functions, after the factory has initialized the
%% checked Core case. The Erlang case returns true/ok; Gleam functions return Nil.
run_case(Cases, Index) ->
    {_, Run} = lists:nth(Index + 1, Cases), Run(), nil.
