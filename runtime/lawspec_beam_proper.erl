%% @doc PropEr generators retain PropEr's own shrink trees. Shrinking a bound
%% input rebuilds dependent generators and reapplies every domain predicate.
%% ref:DEC-native-property-frameworks ref:DEC-shrink-within-domain
-module(lawspec_beam_proper).
-export([generator/5, bind/2, constrain/2, refine_input/2, complete/1, check/3]).

%% An empty dependent range retries the whole tuple, including earlier inputs.
%% Retrying only its final input would never escape the empty range.
bind(Type, Build) -> proper_types:bind(Type, fun
    ('$lawspec_empty_domain') -> proper_types:exactly('$lawspec_empty_domain');
    (Value) -> Build(Value)
end, false).
constrain(Type, Predicate) -> proper_types:add_constraint(Type, fun
    ('$lawspec_empty_domain') -> true;
    (Value) -> Predicate(Value)
end, true).
complete(Type) -> proper_types:add_constraint(Type, fun(V) -> V =/= '$lawspec_empty_domain' end, true).

%% A quantifier's predicate may depend on previous inputs. Reject at the
%% tuple's root so that an impossible prefix is redrawn and can also shrink.
refine_input(Type, Predicate) -> bind(Type, fun(Value) ->
    case Predicate(Value) of
        true -> proper_types:exactly(Value);
        false -> proper_types:exactly('$lawspec_empty_domain')
    end
end).

generator(T, Schema, Symbols, Bounds, Witnesses) ->
    proper_types:sized(fun(Size) ->
        Limit = lists:max([64 | [value_nodes(V) || V <- Witnesses]]),
        Minimum = minimum(T, Schema, Limit),
        case Minimum of
            none -> erlang:error({lawspec, {no_structural_generator, T}});
            _ ->
                Native = build(T, Schema, Symbols, max(Minimum, Size + 1), Bounds),
                case Witnesses of
                    [] -> Native;
                    _ -> proper_types:frequency([{1, proper_types:elements(Witnesses)}, {9, Native}])
                end
        end
    end).

value_nodes({ls_data, _, Fields}) -> 1 + lists:sum([value_nodes(V) || V <- Fields]);
value_nodes({ls_presence, _, {some, V}}) -> 1 + value_nodes(V);
value_nodes(Vs) when is_list(Vs) -> 1 + lists:sum([1 + value_nodes(V) || V <- Vs]);
value_nodes(_) -> 1.

build({<<"List">>, [T]}, S, Symbols, Budget, _) ->
    case minimum(T, S, Budget - 1) of
        none -> proper_types:exactly([]);
        Cost -> bind(proper_types:integer(0, (Budget - 1) div Cost), fun
            (0) -> proper_types:exactly([]);
            (Count) -> proper_types:vector(Count, build(T, S, Symbols, (Budget - 1) div Count, []))
        end)
    end;
build({Name, [T]}, S, Symbols, Budget, _) when Name =:= <<"Optional">>; Name =:= <<"Nullable">> ->
    Empty = proper_types:exactly({ls_presence, Name, none}),
    case minimum(T, S, Budget - 1) of
        none -> Empty;
        _ -> proper_types:oneof([Empty, bind(build(T, S, Symbols, Budget - 1, []),
            fun(V) -> {ls_presence, Name, {some, V}} end)])
    end;
build(T, S, Symbols, Budget, Bounds) ->
    case lawspec_beam_schema:constructors(T, S) of
        none -> scalar(T, maps:get(bits, S), Symbols, Bounds);
        Constructors ->
            Choices = [constructor(C, Allocation, S, Symbols) || C <- Constructors,
                Allocation <- [allocation(maps:get(fields, C), S, Budget - 1)], Allocation =/= none],
            constrain(proper_types:oneof(Choices), fun(V) -> accepted(V, T, S) end)
    end.

constructor(C, Allocation, S, Symbols) ->
    Fields = maps:get(fields, C),
    Types = [build(T, S, Symbols, Budget, []) || {{_, T}, Budget} <- lists:zip(Fields, Allocation)],
    bind(proper_types:fixed_list(Types), fun(Values) -> {ls_data, maps:get(tag, C), Values} end).

accepted(V, T, S) ->
    try lawspec_beam_schema:validate(V, T, S), true catch
        error:{lawspec, {refinement_violation, _}} -> false
    end.

%% The budget counts structural nodes, including scalar leaves. Searching the
%% finite budget terminates for recursive types without assuming a base case.
%% ref:DEC-structural-size-budget
minimum(_, _, Limit) when Limit < 1 -> none;
minimum(T, S, Limit) ->
    Key = {T, S, Limit},
    Cache = case get({?MODULE, minimum}) of undefined -> #{}; Existing -> Existing end,
    case maps:find(Key, Cache) of
        {ok, Cost} -> Cost;
        error ->
            Cost = minimum(T, S, 1, Limit),
            %% Recursive calls have filled entries too; preserve them.
            Current = case get({?MODULE, minimum}) of undefined -> #{}; Populated -> Populated end,
            put({?MODULE, minimum}, Current#{Key => Cost}),
            Cost
    end.
minimum(_, _, Cost, Limit) when Cost > Limit -> none;
minimum(T, S, Cost, Limit) ->
    case inhabited(T, S, Cost) of true -> Cost; false -> minimum(T, S, Cost + 1, Limit) end.

inhabited(_, _, Budget) when Budget < 1 -> false;
inhabited({Name, _}, _, _) when Name =:= <<"List">>; Name =:= <<"Optional">>; Name =:= <<"Nullable">> -> true;
inhabited(T, S, Budget) ->
    case lawspec_beam_schema:constructors(T, S) of
        none -> true;
        Cs -> lists:any(fun(C) -> allocation(maps:get(fields, C), S, Budget - 1) =/= none end, Cs)
    end.

allocation(Fields, S, Budget) ->
    case costs(Fields, S, Budget) of
        none -> none;
        [] -> [];
        Minimums ->
            Extra = Budget - lists:sum(Minimums), Count = length(Minimums),
            [Cost + Extra div Count + case I =< Extra rem Count of true -> 1; false -> 0 end
                || {I, Cost} <- lists:enumerate(Minimums)]
    end.
costs([], _, Budget) when Budget >= 0 -> [];
costs(_, _, Budget) when Budget < 1 -> none;
costs([{_, T} | Fields], S, Budget) ->
    case minimum(T, S, Budget) of
        none -> none;
        Cost -> case costs(Fields, S, Budget - Cost) of none -> none; Rest -> [Cost | Rest] end
    end.

scalar({<<"Bool">>, []}, _, _, _) -> proper_types:boolean();
scalar({<<"Unit">>, []}, _, _, _) -> proper_types:exactly(ls_unit);
scalar({<<"Null">>, []}, _, _, _) -> proper_types:exactly(ls_null);
scalar({<<"Undefined">>, []}, _, _, _) -> proper_types:exactly(ls_undefined);
scalar({<<"Rational">>, []}, _, _, _) ->
    bind({proper_types:integer(), proper_types:pos_integer()}, fun({N, D}) -> lawspec_beam_scalar:ratio(N, D) end);
scalar({<<"Decimal">>, []}, _, _, _) ->
    bind({proper_types:integer(), proper_types:integer()}, fun({C, E}) -> lawspec_beam_scalar:decimal(C, E) end);
scalar({<<"Float32">>, []}, _, _, _) -> ieee(32);
scalar({<<"Float64">>, []}, _, _, _) -> ieee(64);
scalar({Name, []}, _, _, _) when Name =:= <<"Complex64">>; Name =:= <<"Complex128">> ->
    W = case Name of <<"Complex64">> -> 32; _ -> 64 end,
    bind({ieee(W), ieee(W)}, fun({R, I}) -> {ls_complex, W, R, I} end);
scalar({<<"Char">>, []}, _, _, _) -> unicode_scalar();
scalar({<<"CodePoint">>, []}, _, _, _) -> proper_types:integer(0, 16#10ffff);
scalar({<<"CodeUnit16">>, []}, _, _, _) -> proper_types:integer(0, 16#ffff);
scalar({<<"Text">>, []}, _, _, _) -> bind(proper_types:list(unicode_scalar()), fun unicode:characters_to_binary/1);
scalar({<<"Bytes">>, []}, _, _, _) -> proper_types:binary();
scalar({Name, []}, _, _, _) when Name =:= <<"CodePointText">>; Name =:= <<"Utf16Text">> ->
    Max = case Name of <<"CodePointText">> -> 16#10ffff; _ -> 16#ffff end,
    bind(proper_types:list(proper_types:integer(0, Max)), fun(Units) -> {ls_raw, Name, Units} end);
scalar({<<"Symbol">>, []}, _, Symbols, _) ->
    bind(proper_types:non_neg_integer(), fun(N) ->
        Key = integer_to_binary(N), {ls_symbol, {{Symbols, generated}, Key}, Key}
    end);
scalar({Name, []}, Bits, _, Bounds) ->
    {Lo, Hi} = lists:foldl(fun limit/2, lawspec_beam_scalar:bounds(Name, Bits), Bounds),
    case Lo =/= none andalso Hi =/= none andalso Lo > Hi of
        true -> proper_types:exactly('$lawspec_empty_domain');
        false -> proper_types:integer(ext(Lo), ext(Hi))
    end.

ieee(Width) -> bind(proper_types:integer(0, (1 bsl Width) - 1),
    fun(Bits) -> lawspec_beam_scalar:float_bits(Width, Bits) end).
unicode_scalar() -> proper_types:oneof([proper_types:integer(0, 16#d7ff), proper_types:integer(16#e000, 16#10ffff)]).
ext(none) -> inf;
ext(N) -> N.

limit({Op, V}, {Lo, Hi}) ->
    {N, D} = lawspec_beam_scalar:exact(V),
    Floor = N div D - case N < 0 andalso N rem D =/= 0 of true -> 1; false -> 0 end,
    Ceil = Floor + case N rem D =/= 0 of true -> 1; false -> 0 end,
    case Op of
        <<">">> -> {lower(Lo, Floor + 1), Hi};
        <<">=">> -> {lower(Lo, Ceil), Hi};
        <<"<">> -> {Lo, upper(Hi, Ceil - 1)};
        <<"<=">> -> {Lo, upper(Hi, Floor)};
        <<"==">> -> {lower(Lo, Ceil), upper(Hi, Floor)};
        _ -> {Lo, Hi}
    end.
lower(none, N) -> N;
lower(L, N) -> max(L, N).
upper(none, N) -> N;
upper(H, N) -> min(H, N).

%% @doc Seed the framework once, then let its generator and shrinker run.
%% A generation error or an exhausted discard budget fails the test.
%% ref:DEC-never-pass-vacuously
check(Label, Property, Options) ->
    Seed = case os:getenv("LAWSPEC_SEED") of
        false -> erlang:system_time(nanosecond) bxor erlang:unique_integer([positive]);
        Text -> list_to_integer(Text)
    end,
    Configured = proper:setup(fun() ->
        proper_arith:rand_restart({Seed band 16#ffffffff, (Seed bsr 32) band 16#ffffffff, 1}),
        fun() -> ok end
    end, Property),
    Previous = erase({?MODULE, minimum}),
    try
        case proper:quickcheck(Configured, Options) of
            true -> ok;
            Result -> erlang:error({lawspec, {property_failed, Label, {seed, Seed}, Result}})
        end
    after
        case Previous of
            undefined -> erase({?MODULE, minimum});
            _ -> put({?MODULE, minimum}, Previous)
        end
    end.
