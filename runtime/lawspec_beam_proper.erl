%% @doc PropEr generators retain PropEr's own shrink trees. Shrinking a bound
%% input rebuilds dependent generators and reapplies every domain predicate.
%% ref:DEC-native-property-frameworks ref:DEC-shrink-within-domain
-module(lawspec_beam_proper).
-export([generator/5, generator/6, map/2, bind/2, constrain/2, refine_input/2, complete/1, check/3, exactly/1, sized/1,
    frequency/1, oneof/1, integer/2, list/1, vector/2, fixed_list/1, binary/0, forall/2]).

%% An empty dependent range retries the whole tuple, including earlier inputs.
%% Retrying only its final input would never escape the empty range.
map(Type, Convert) ->
    case proper_types:is_raw_type(Type) of
        true -> proper_types:bind(Type, fun(Value) -> proper_types:exactly(Convert(Value)) end, false);
        false -> erlang:error({lawspec, expected_proper_generator})
    end.
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
    lawspec_beam_generators:generator(?MODULE, T, Schema, Symbols, Bounds, Witnesses).
generator(T, Schema, Symbols, Bounds, Witnesses, Index) ->
    lawspec_beam_generators:generator(?MODULE, T, Schema, Symbols, Bounds, Witnesses, Index).

exactly(Value) -> proper_types:exactly(Value).
sized(Build) -> proper_types:sized(Build).
frequency(Choices) -> proper_types:frequency(Choices).
oneof(Choices) -> proper_types:oneof(Choices).
integer(Lo, Hi) -> proper_types:integer(ext(Lo), ext(Hi)).
ext(none) -> inf;
ext(N) -> N.
list(Type) -> proper_types:list(Type).
vector(Count, Type) -> proper_types:vector(Count, Type).
fixed_list(Types) -> map(proper_types:fixed_list(Types), fun(Values) ->
    case lists:member('$lawspec_empty_domain', Values) of true -> '$lawspec_empty_domain'; false -> Values end
end).
binary() -> proper_types:binary().
forall(Type, Predicate) -> proper:forall(Type, Predicate).

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
    lawspec_beam_generators:with_cache(fun() ->
        case proper:quickcheck(Configured, Options) of
            true -> ok;
            Result -> erlang:error({lawspec, {property_failed, Label, {seed, Seed}, Result}})
        end
    end).
