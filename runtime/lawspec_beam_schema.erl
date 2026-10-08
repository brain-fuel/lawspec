%% @doc Core schemas are the boundary between portable values and native
%% Erlang tuples, Elixir structs or Gleam constructors. Shapes, GADT equations,
%% witnesses, index guards and field predicates are checked by the same walk.
%% ref:DEC-typed-core-boundary ref:DEC-native-bindings-typed-identity
-module(lawspec_beam_schema).
-export([new/3, validate/3, construct/4, match/2, constructors/2, witness_instances/1,
    to_native/3, from_native/3, all_payloads/4, substitute/2, index/4,
    check_type/2, handle/2, with_codecs/2, with_bindings/3, constructor_shape/2, type_key/1]).
-export_type([schema/0, value/0, type_ref/0]).

-type type_ref() :: {binary(), [type_ref()]} | {parameter, non_neg_integer()}.
-type value() :: term().
-opaque schema() :: #{definitions := map(), arities := map(), bits := 32 | 64,
    codecs := map()}.

new(Definitions, Primitives, Bits) when Bits =:= 32; Bits =:= 64 ->
    Builtins = [{<<"List">>, 1}, {<<"Maybe">>, 1}, {<<"Either">>, 2},
        {<<"Nullable">>, 1}, {<<"Optional">>, 1}],
    Names = [maps:get(name, D) || D <- Definitions],
    Unique = Names ++ Primitives ++ [N || {N, _} <- Builtins],
    require(length(Unique) =:= length(lists:usort(Unique)), duplicate_type),
    Ds = maps:from_list([{maps:get(name, D), D} || D <- Definitions]),
    Arities = maps:from_list([{N, 0} || N <- Primitives] ++ Builtins ++
        [{maps:get(name, D), maps:get(parameters, D)} || D <- Definitions]),
    Schema = #{definitions => Ds, arities => Arities, bits => Bits, codecs => #{}},
    Tags = [maps:get(tag, C) || D <- Definitions, C <- maps:get(constructors, D)],
    require(length(Tags) =:= length(lists:usort(Tags)), duplicate_constructor),
    lists:foreach(fun(D) -> audit_definition(D, Schema) end, Definitions),
    Schema.

audit_definition(#{parameters := Count, constructors := Cs}, S) ->
    require(is_integer(Count) andalso Count >= 0, invalid_parameter_count),
    lists:foreach(fun(C) ->
        Fields = maps:get(fields, C),
        Names = [N || {N, _} <- Fields],
        require(length(Names) =:= length(lists:usort(Names)), duplicate_field),
        Extra = maps:get(existentials, C, 0),
        require(is_integer(Extra) andalso Extra >= 0, invalid_existentials),
        Scope = Count + Extra,
        lists:foreach(fun({_, T}) -> check_type(T, Scope, S) end, Fields),
        lists:foreach(fun({I, T}) ->
            require(is_integer(I) andalso I >= 0 andalso I < Count, invalid_refined_parameter),
            check_type(T, Scope, S)
        end, maps:get(refinements, C, [])),
        Witnesses = maps:get(witnesses, C, []),
        require(length(Witnesses) =< length(Fields), invalid_witnesses),
        lists:foreach(fun(I) ->
            require(is_integer(I) andalso I >= Count andalso I < Scope, invalid_witness)
        end, Witnesses),
        lists:foreach(fun(P) -> require(is_function(P, 3), invalid_predicate) end,
            maps:get(predicates, C, []))
    end, Cs).

check_type(T, S) -> check_type(T, 0, S).
check_type(T, Scope, S) when is_binary(T) -> check_type(lawspec_beam_scalar:type(T), Scope, S);
check_type({parameter, I}, Scope, _) ->
    require(is_integer(I) andalso I >= 0 andalso I < Scope, unbound_schema_parameter);
check_type({Name, Args}, Scope, #{arities := Arities} = S) when is_binary(Name), is_list(Args) ->
    require(maps:get(Name, Arities, missing) =:= length(Args), {unknown_type_or_arity, Name}),
    lists:foreach(fun(T) -> check_type(T, Scope, S) end, Args);
check_type(_, _, _) -> fail(invalid_type_reference).

substitute({parameter, I} = T, Known) -> maps:get(I, Known, T);
substitute({Name, Args}, Known) -> {Name, [substitute(T, Known) || T <- Args]}.

type_key(T) when is_binary(T) -> T;
type_key({Name, []}) -> Name;
type_key({Name, Args}) ->
    iolist_to_binary([Name, [[<<" (">>, type_key(T), <<")">>] || T <- Args]]).

%% @doc GADT equations can bind existential parameters, while a witnessed
%% existential stays open until its trailing Text field supplies its type.
%% ref:DEC-gadts-and-index-arithmetic
constructors(T, S) when is_binary(T) -> constructors(lawspec_beam_scalar:type(T), S);
constructors({Name, Args} = T, #{definitions := Ds} = S) ->
    check_type(T, S),
    case maps:find(Name, Ds) of
        error -> builtin_constructors(Name, Args);
        {ok, D} -> lists:filtermap(fun(C) -> instantiate(C, Args) end, maps:get(constructors, D))
    end.

instantiate(C, Args) ->
    Known = maps:from_list(lists:zip(lists:seq(0, length(Args) - 1), Args)),
    Bound = lists:foldl(fun
        (_, mismatch) -> mismatch;
        ({I, Pattern}, K) -> unify(Pattern, lists:nth(I + 1, Args), K)
    end, Known, maps:get(refinements, C, [])),
    case Bound of
        mismatch -> false;
        _ -> {true, C#{fields => [{N, substitute(T, Bound)} || {N, T} <- maps:get(fields, C)]}}
    end.

unify({parameter, I}, Actual, Known) ->
    case maps:find(I, Known) of
        error -> Known#{I => Actual};
        {ok, Actual} -> Known;
        _ -> mismatch
    end;
unify({Name, Ps}, {Name, As}, Known) when length(Ps) =:= length(As) ->
    lists:foldl(fun
        (_, mismatch) -> mismatch;
        ({P, A}, K) -> unify(P, A, K)
    end, Known, lists:zip(Ps, As));
unify(_, _, _) -> mismatch.

builtin_constructors(<<"Maybe">>, [T]) ->
    [#{tag => <<"Maybe::Nothing">>, fields => [], native_tag => nothing},
     #{tag => <<"Maybe::Just">>, fields => [{<<"value">>, T}], native_tag => just}];
builtin_constructors(<<"Either">>, [A, B]) ->
    [#{tag => <<"Either::Left">>, fields => [{<<"value">>, A}], native_tag => left},
     #{tag => <<"Either::Right">>, fields => [{<<"value">>, B}], native_tag => right}];
builtin_constructors(_, _) -> none.

with_codecs(#{codecs := Existing} = S, Codecs) ->
    maps:foreach(fun(Name, #{encode := Encode, decode := Decode}) ->
        require(maps:is_key(Name, maps:get(arities, S)), {unknown_codec_type, Name}),
        require(is_function(Encode, 2) andalso is_function(Decode, 2), invalid_codec)
    end, Codecs),
    S#{codecs => maps:merge(Existing, Codecs)}.

%% Application mappings change native shapes while keeping the same logical
%% contracts. A codec receives canonical native values, not internal ls_data
%% tuples; its child converters cross between canonical and bound native data.
%% ref:DEC-native-bindings-typed-identity
with_bindings(#{definitions := Definitions} = S, Shapes, Hooks) ->
    Constructors = maps:from_list([{maps:get(tag, C), Name} || {Name, D} <- maps:to_list(Definitions),
        C <- maps:get(constructors, D)]),
    maps:foreach(fun(Tag, Shape) ->
        require(maps:is_key(Tag, Constructors), {unknown_native_constructor, Tag}),
        case Shape of
            #{native_tag := Atom} when map_size(Shape) =:= 1, is_atom(Atom) -> ok;
            #{encode := Encode, decode := Decode} when map_size(Shape) =:= 2,
                    is_function(Encode, 1), is_function(Decode, 1) -> ok;
            _ -> fail({invalid_native_shape, Tag})
        end
    end, Shapes),
    NativeShapes = maps:merge(maps:get(native_shapes, S, #{}), Shapes),
    Existing = maps:get(native_codecs, S, #{}),
    Combined = maps:merge(Existing, Hooks),
    maps:foreach(fun(Name, Hook) ->
        require(maps:is_key(Name, Definitions) andalso
            maps:get(constructors, maps:get(Name, Definitions)) =/= [], {unknown_native_codec, Name}),
        require(not lists:any(fun(Tag) -> maps:get(Tag, Constructors) =:= Name end, maps:keys(NativeShapes)),
            {conflicting_native_binding, Name}),
        case Hook of
            #{encode := Encode, decode := Decode} when map_size(Hook) =:= 2,
                    is_function(Encode, 2), is_function(Decode, 2) -> ok;
            _ -> fail({invalid_native_codec, Name})
        end
    end, Combined),
    Native = maps:map(fun(_, D) -> D#{constructors => [case maps:find(maps:get(tag, C), Shapes) of
        error -> C;
        {ok, Shape} -> maps:merge(maps:without([native_tag, encode, decode], C), Shape)
    end || C <- maps:get(constructors, D)]} end, Definitions),
    S#{definitions => Native, native_codecs => Combined, native_shapes => NativeShapes,
        canonical => maps:get(canonical, S, S)}.

%% A generated Gleam helper calls the application's constructor by field name.
%% Unique markers reveal the compiler's tuple positions without guessing its
%% field order or duplicating its constructor-name normalization. The helper
%% only constructs a custom-type value; it never calls application functions.
%% ref:DEC-native-bindings-typed-identity
constructor_shape(Encode, Count) when is_function(Encode, 1), is_integer(Count), Count >= 0 ->
    Markers = [make_ref() || _ <- lists:seq(1, Count)],
    Template = Encode(Markers),
    case {Count, Template} of
        {0, Tag} when is_atom(Tag) -> #{native_tag => Tag};
        {_, Tuple} when is_tuple(Tuple), tuple_size(Tuple) =:= Count + 1,
                is_atom(element(1, Tuple)) ->
            Positions = [[I || I <- lists:seq(2, Count + 1), element(I, Tuple) =:= Marker] || Marker <- Markers],
            require(lists:all(fun(P) -> length(P) =:= 1 end, Positions), invalid_constructor_shape),
            Tag = element(1, Tuple),
            #{encode => Encode, decode => fun
                (V) when is_tuple(V), tuple_size(V) =:= Count + 1, element(1, V) =:= Tag ->
                    {ok, [element(I, V) || [I] <- Positions]};
                (_) -> no_match
            end};
        _ -> fail(invalid_constructor_shape)
    end.

validate(Value, T, S) when is_binary(T) -> validate(Value, lawspec_beam_scalar:type(T), S);
validate(Value, T, S) -> check_type(T, S), walk(Value, T, S, validate).

to_native(Value, T, S) when is_binary(T) -> to_native(Value, lawspec_beam_scalar:type(T), S);
to_native(Value, T, S) -> walk(validate(Value, T, S), T, S, encode).
from_native(Value, T, S) when is_binary(T) -> from_native(Value, lawspec_beam_scalar:type(T), S);
from_native(Value, T, S) -> check_type(T, S), validate(walk(Value, T, S, decode), T, S).

walk(Value, {Name, Args} = T, #{codecs := Codecs} = S, Mode)
        when Mode =:= encode; Mode =:= decode ->
    case maps:find(Name, maps:get(native_codecs, S, #{})) of
        {ok, Hook} -> native_codec(Value, T, S, Mode, Hook);
        error -> case maps:find(Name, Codecs) of
        {ok, Codec} ->
            Children = [fun(V) -> case Mode of
                encode -> to_native(V, Child, S);
                decode -> from_native(V, Child, S)
            end end || Child <- Args],
            (maps:get(Mode, Codec))(Value, Children);
            error -> walk_shape(Value, T, S, Mode)
        end
    end;
walk(Value, T, S, Mode) -> walk_shape(Value, T, S, Mode).

native_codec(Value, {Name, Args} = T, #{canonical := Canonical} = S, Mode, Hook) ->
    try
        Children = [fun(V) -> case Mode of
            encode -> to_native(from_native(V, Child, Canonical), Child, S);
            decode -> to_native(from_native(V, Child, S), Child, Canonical)
        end end || Child <- Args],
        Convert = maps:get(Mode, Hook),
        case Mode of
            encode -> Convert(to_native(Value, T, Canonical), Children);
            decode -> from_native(Convert(Value, Children), T, Canonical)
        end
    catch Kind:Reason:Stack ->
        erlang:raise(error, {lawspec, {native_codec, Name, Mode, Kind, Reason}}, Stack)
    end.

walk_shape(Values, {<<"List">>, [T]}, S, Mode) when is_list(Values) ->
    [walk(V, T, S, Mode) || V <- Values];
walk_shape(ls_unit, {<<"Unit">>, []}, _, encode) -> ok;
walk_shape(ok, {<<"Unit">>, []}, _, decode) -> ls_unit;
walk_shape(ls_null, {<<"Null">>, []}, _, encode) -> null;
walk_shape(null, {<<"Null">>, []}, _, decode) -> ls_null;
walk_shape(ls_undefined, {<<"Undefined">>, []}, _, encode) -> undefined;
walk_shape(undefined, {<<"Undefined">>, []}, _, decode) -> ls_undefined;
walk_shape({ls_raw, Name, Units}, {Name, []}, _, encode)
        when Name =:= <<"CodePointText">>; Name =:= <<"Utf16Text">> -> Units;
walk_shape(Units, {Name, []}, _, decode) when is_list(Units),
        (Name =:= <<"CodePointText">> orelse Name =:= <<"Utf16Text">>) -> {ls_raw, Name, Units};
walk_shape({ls_presence, <<"Optional">>, none}, {<<"Optional">>, [_]}, _, encode) -> none;
walk_shape({ls_presence, <<"Nullable">>, none}, {<<"Nullable">>, [_]}, _, encode) -> null;
walk_shape({ls_presence, Name, {some, V}}, {Name, [T]}, S, encode)
        when Name =:= <<"Optional">>; Name =:= <<"Nullable">> ->
    Tag = case Name of <<"Optional">> -> some; <<"Nullable">> -> non_null end,
    {Tag, walk(V, T, S, encode)};
walk_shape(none, {<<"Optional">>, [_]}, _, decode) -> {ls_presence, <<"Optional">>, none};
walk_shape(null, {<<"Nullable">>, [_]}, _, decode) -> {ls_presence, <<"Nullable">>, none};
walk_shape({some, V}, {<<"Optional">>, [T]}, S, decode) ->
    {ls_presence, <<"Optional">>, {some, walk(V, T, S, decode)}};
walk_shape({non_null, V}, {<<"Nullable">>, [T]}, S, decode) ->
    {ls_presence, <<"Nullable">>, {some, walk(V, T, S, decode)}};
walk_shape({ls_presence, Name, P}, {Name, [T]}, S, Mode)
        when Name =:= <<"Optional">>; Name =:= <<"Nullable">> ->
    {ls_presence, Name, case P of none -> none; {some, V} -> {some, walk(V, T, S, Mode)} end};
walk_shape(Value, {Name, _} = T, #{definitions := Ds, bits := Bits} = S, Mode) ->
    case maps:find(Name, Ds) of
        {ok, #{handle := true}} -> case Mode of
            encode -> {ls_handle, Name, Identity} = checked_handle(Value, Name), Identity;
            decode -> case Value of
                {ls_handle, _, _} -> checked_handle(Value, Name);
                _ -> handle(Value, Name)
            end;
            _ -> checked_handle(Value, Name)
        end;
        _ -> case constructors(T, S) of
            none -> lawspec_beam_scalar:validate(Value, T, Bits);
            Cs -> walk_data(Value, T, Cs, S, Mode)
        end
    end.

walk_data(Value, {_, Args}, Cs, S, Mode) ->
    {C, Fields} = case {Mode, Value} of
        {decode, _} -> native_fields(Value, Cs);
        {_, {ls_data, ValueTag, Fs}} -> {find_constructor(ValueTag, Cs), Fs};
        _ -> fail(expected_data)
    end,
    Tag = maps:get(tag, C),
    Declared = maps:get(fields, C),
    require(is_list(Fields) andalso length(Fields) =:= length(Declared), {wrong_field_count, Tag}),
    Typed = witnessed(C, Fields, S),
    Converted = case Mode of
        shallow -> Fields;
        _ -> [walk(F, T, S, Mode) || {F, {_, T}} <- lists:zip(Fields, Typed)]
    end,
    case Mode of
        encode -> native_construct(C, Converted);
        decode -> {ls_data, Tag, Converted};
        _ ->
            check_predicates(C, Args, Converted, S),
            check_indices(C#{fields => Typed}, Converted, S),
            {ls_data, Tag, Converted}
    end.

find_constructor(Tag, Cs) ->
    case [C || C <- Cs, maps:get(tag, C) =:= Tag] of
        [C] -> C;
        _ -> fail({foreign_constructor, Tag})
    end.

witnessed(C, Values, S) ->
    Witnesses = maps:get(witnesses, C, []),
    Texts = lists:nthtail(length(Values) - length(Witnesses), Values),
    Known = maps:from_list([{I, lawspec_beam_scalar:type(Text)} || {I, Text} <- lists:zip(Witnesses, Texts)]),
    maps:foreach(fun(_, T) -> check_type(T, S) end, Known),
    [{N, substitute(T, Known)} || {N, T} <- maps:get(fields, C)].

%% Generated free existentials use Core's finite Bool/Int32 witness pool.
%% GADT-bound existentials were already substituted by instantiate/2.
%% ref:DEC-gadts-and-index-arithmetic
witness_instances(C) ->
    Identities = maps:get(witnesses, C, []),
    Pool = [{<<"Bool">>, []}, {<<"Int32">>, []}],
    Assignments = lists:foldl(fun(I, Previous) ->
        [Known#{I => T} || Known <- Previous, T <- Pool]
    end, [#{}], Identities),
    Fields = lists:sublist(maps:get(fields, C), length(maps:get(fields, C)) - length(Identities)),
    [C#{fields => [{N, substitute(T, Known)} || {N, T} <- Fields],
        witness_values => [type_key(maps:get(I, Known)) || I <- Identities]} || Known <- Assignments].

check_predicates(C, Args, Values, S) ->
    lists:foreach(fun(Predicate) ->
        case Predicate(S, Args, Values) of
            true -> ok;
            false -> fail({refinement_violation, maps:get(tag, C)});
            _ -> fail(non_boolean_predicate)
        end
    end, maps:get(predicates, C, [])).

native_construct(#{encode := F}, Fields) -> F(Fields);
native_construct(#{native_tag := Tag}, []) -> Tag;
native_construct(#{native_tag := Tag}, Fields) -> list_to_tuple([Tag | Fields]).

native_fields(_, []) -> fail(invalid_native_constructor);
native_fields(V, [#{decode := F} = C | Cs]) ->
    case F(V) of {ok, Fs} -> {C, Fs}; no_match -> native_fields(V, Cs) end;
native_fields(V, [#{native_tag := Tag} = C | Cs]) ->
    case V of
        Tag when is_atom(Tag) -> {C, []};
        Tuple when is_tuple(Tuple), tuple_size(Tuple) > 0, element(1, Tuple) =:= Tag ->
            [_ | Fields] = tuple_to_list(Tuple), {C, Fields};
        _ -> native_fields(V, Cs)
    end;
native_fields(V, [_ | Cs]) -> native_fields(V, Cs).

%% @doc Construction is shallow because its fields are already checked Core
%% values. A native boundary performs a full walk exactly once.
%% ref:DEC-structural-size-budget
construct(Tag, Fields, T, S) when is_binary(T) ->
    construct(Tag, Fields, lawspec_beam_scalar:type(T), S);
construct(<<"List::Nil">>, [], {<<"List">>, [_]}, _) -> [];
construct(<<"List::Cons">>, [H, Tail], {<<"List">>, [_]}, _) when is_list(Tail) -> [H | Tail];
construct(Tag, Fields, T, S) ->
    check_type(T, S), walk_data({ls_data, Tag, Fields}, T, constructors(T, S), S, shallow).

match([], Branches) -> (maps:get(<<"List::Nil">>, Branches))([]);
match([H | T], Branches) -> (maps:get(<<"List::Cons">>, Branches))([H, T]);
match({ls_data, Tag, Fields}, Branches) -> (maps:get(Tag, Branches))(Fields).

%% @doc BEAM handles carry identity explicitly. A native process, port or
%% reference keeps its identity across repeated crossings of the boundary.
%% ref:DEC-native-bindings-typed-identity
handle(Value, Name) when is_pid(Value); is_reference(Value); is_port(Value) ->
    {ls_handle, Name, Value};
handle(_, _) -> fail(handle_requires_identity).
checked_handle({ls_handle, Name, Identity} = H, Name)
        when is_pid(Identity); is_reference(Identity); is_port(Identity) -> H;
checked_handle(_, Name) -> fail({invalid_handle, Name}).

%% @doc Index terms use the same prefix language as Core's schema metadata.
%% Subtraction is undefined below zero and division is undefined at zero.
%% ref:DEC-gadts-and-index-arithmetic
index({ls_data, Tag, Values}, T, Position, S) ->
    C0 = find_constructor(Tag, constructors(T, S)),
    C = C0#{fields => witnessed(C0, Values, S)},
    Terms = [Tokens || Text <- maps:get(indices, C, []),
        Tokens <- [tokens(Text)], not guard_tokens(Tokens)],
    require(Position >= 0 andalso Position < length(Terms), no_index),
    {Value, []} = eval_index(lists:nth(Position + 1, Terms), C, Values, S),
    Value.

check_indices(C, Values, S) ->
    lists:foreach(fun(Text) -> case tokens(Text) of
        [Op | Rest] when Op =:= <<"==">>; Op =:= <<">=">> ->
            {A, Next} = eval_index(Rest, C, Values, S),
            {B, []} = eval_index(Next, C, Values, S),
            require(A =/= undefined andalso B =/= undefined andalso
                case Op of <<"==">> -> A =:= B; <<">=">> -> A >= B end,
                {refinement_violation, {index_guard, Text}});
        _ -> ok
    end end, maps:get(indices, C, [])).

tokens(Text) -> binary:split(Text, <<" ">>, [global, trim_all]).
guard_tokens([<<"==">> | _]) -> true;
guard_tokens([<<">=">> | _]) -> true;
guard_tokens(_) -> false.
eval_index([<<"c", N/binary>> | Rest], _, _, _) -> {binary_to_integer(N), Rest};
eval_index([<<"f", Field/binary>> | Rest], C, Values, S) ->
    {P, I} = case binary:split(Field, <<".">>) of
        [Pos] -> {binary_to_integer(Pos), 0};
        [Pos, Idx] -> {binary_to_integer(Pos), binary_to_integer(Idx)}
    end,
    {_, T} = lists:nth(P + 1, maps:get(fields, C)),
    {index(lists:nth(P + 1, Values), T, I, S), Rest};
eval_index([Op | Rest], C, Values, S) ->
    {A, Next} = eval_index(Rest, C, Values, S),
    {B, After} = eval_index(Next, C, Values, S),
    {index_binary(Op, A, B), After}.
index_binary(_, undefined, _) -> undefined;
index_binary(_, _, undefined) -> undefined;
index_binary(<<"+">>, A, B) -> A + B;
index_binary(<<"-">>, A, B) when A >= B -> A - B;
index_binary(<<"*">>, A, B) -> A * B;
index_binary(<<"div">>, A, B) when B > 0 -> A div B;
index_binary(<<"mod">>, A, B) when B > 0 -> A rem B;
index_binary(<<"^">>, A, B) when B >= 0, B =< 64 ->
    lawspec_beam_scalar:binary(<<"pow">>, A, B, <<"Integer">>, <<"Integer">>);
index_binary(_, _, _) -> undefined.

%% @doc Payload predicates follow declaration parameters rather than the
%% concrete types they happen to instantiate to. Fixed fields are not payloads.
%% ref:DEC-typed-core-boundary
all_payloads(Value, T, Predicates, S) when is_binary(T) ->
    all_payloads(Value, lawspec_beam_scalar:type(T), Predicates, S);
all_payloads(Value, {Name, Args} = T, Predicates, S) ->
    require(length(Args) =:= length(Predicates), payload_arity_mismatch),
    _ = validate(Value, T, S),
    Known = [{predicate, P} || P <- Predicates],
    payload({Name, Known}, Value, S).

recipe({parameter, I}, Args) ->
    case I < length(Args) of true -> lists:nth(I + 1, Args); false -> none end;
recipe({Name, Fields}, Args) ->
    Children = [recipe(T, Args) || T <- Fields],
    case lists:all(fun(T) -> T =:= none end, Children) of
        true -> none;
        false -> {Name, Children}
    end.
payload(none, _, _) -> true;
payload({predicate, P}, Value, _) ->
    Result = P(Value), require(is_boolean(Result), non_boolean_payload_predicate), Result;
payload({<<"List">>, [T]}, Values, S) -> lists:all(fun(V) -> payload(T, V, S) end, Values);
payload({Name, [_]}, {ls_presence, Name, none}, _) -> true;
payload({Name, [T]}, {ls_presence, Name, {some, V}}, S) -> payload(T, V, S);
payload({<<"Maybe">>, [_]}, {ls_data, <<"Maybe::Nothing">>, []}, _) -> true;
payload({<<"Maybe">>, [T]}, {ls_data, <<"Maybe::Just">>, [V]}, S) -> payload(T, V, S);
payload({<<"Either">>, [T, _]}, {ls_data, <<"Either::Left">>, [V]}, S) -> payload(T, V, S);
payload({<<"Either">>, [_, T]}, {ls_data, <<"Either::Right">>, [V]}, S) -> payload(T, V, S);
payload({Name, Args}, {ls_data, Tag, Values}, #{definitions := Ds} = S) ->
    C = find_constructor(Tag, maps:get(constructors, maps:get(Name, Ds))),
    lists:all(fun({{_, T}, V}) -> payload(recipe(T, Args), V, S) end,
        lists:zip(maps:get(fields, C), Values)).

require(true, _) -> ok;
require(false, Reason) -> fail(Reason).
fail(Reason) -> erlang:error({lawspec, Reason}).
