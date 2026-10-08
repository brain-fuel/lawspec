%% @doc Native qcheck combinators and shrink trees. The bounded filter removes
%% invalid shrink candidates; the lazy cap limits qcheck's own shrink traversal.
%% ref:DEC-native-property-frameworks ref:DEC-shrink-within-domain
-module(lawspec_beam_qcheck).
-export([generator/5, bind/2, constrain/2, refine_input/2, complete/1, check/3,
    exactly/1, sized/1, frequency/1, oneof/1, integer/2, list/1, vector/2,
    fixed_list/1, binary/0, forall/2]).

generator(T, Schema, Symbols, Bounds, Witnesses) ->
    lawspec_beam_generators:generator(?MODULE, T, Schema, Symbols, Bounds, Witnesses).
exactly(V) -> qcheck:constant(V).
sized(Build) -> qcheck:sized_from(Build, qcheck:small_non_negative_int()).
frequency([Choice | Choices]) -> qcheck:from_weighted_generators(Choice, Choices).
oneof([Choice | Choices]) -> qcheck:from_generators(Choice, Choices).
list(Type) -> qcheck:list_from(Type).
vector(Count, Type) -> qcheck:fixed_length_list_from(Type, Count).
fixed_list(Types) -> lists:foldr(fun(Type, Tail) ->
    qcheck:map2(Type, Tail, fun(H, T) -> [H | T] end)
end, exactly([]), Types).
binary() -> qcheck:byte_aligned_bit_array().
forall(Type, Predicate) -> {Type, Predicate}.

bind(Type, Build) -> qcheck:bind(Type, fun
    ('$lawspec_empty_domain') -> exactly('$lawspec_empty_domain');
    (Value) -> case Build(Value) of
        {generator, F} = Generator when is_function(F, 1) -> Generator;
        Constant -> exactly(Constant)
    end
end).
constrain(Type, Predicate) -> filter(Type, fun
    ('$lawspec_empty_domain') -> true;
    (Value) -> Predicate(Value)
end).
complete(Type) -> filter(Type, fun(V) -> V =/= '$lawspec_empty_domain' end).
refine_input(Type, Predicate) -> bind(Type, fun(Value) ->
    case Predicate(Value) of true -> Value; false -> '$lawspec_empty_domain' end
end).

filter(Type, Predicate) -> {generator, fun(Seed) ->
    filtered(Type, Predicate, setting(attempts, 100), Seed)
end}.
filtered(_, _, 0, _) -> erlang:error({lawspec, exhausted_generator_attempts});
filtered(Type, Predicate, Attempts, Seed) ->
    {{tree, Value, _} = Tree, Next} = qcheck:generate_tree(Type, Seed),
    case Predicate(Value) of
        true -> {prune(Tree, Predicate), Next};
        false -> filtered(Type, Predicate, Attempts - 1, Next)
    end.
prune({tree, Value, Children}, Predicate) ->
    Valid = 'gleam@yielder':filter(Children, fun({tree, V, _}) -> Predicate(V) end),
    {tree, Value, 'gleam@yielder':map(Valid, fun(Child) -> prune(Child, Predicate) end)}.

%% qcheck's PRNG documents a 32-bit native integer range. Compose its native
%% limb generators for wider values; do not truncate Int64, UInt64 or IEEE bits.
%% Every limb still carries qcheck's shrink tree, and the map stays in-domain.
%% ref:DEC-portable-exact-arithmetic
integer(none, none) -> bind(oneof([exactly(1), exactly(-1)]), fun(Sign) ->
    qcheck:map(non_negative(), fun(N) -> Sign * N end)
end);
integer(Lo, none) -> qcheck:map(non_negative(), fun(N) -> Lo + N end);
integer(none, Hi) -> qcheck:map(non_negative(), fun(N) -> Hi - N end);
integer(Lo, Hi) when Lo > Hi -> exactly('$lawspec_empty_domain');
integer(Lo, Hi) when Hi - Lo < 16#100000000 -> qcheck:bounded_int(Lo, Hi);
integer(Lo, Hi) when Lo >= 0 -> qcheck:map(magnitude(Hi - Lo + 1), fun(N) -> Lo + N end);
integer(Lo, Hi) when Hi =< 0 -> qcheck:map(magnitude(Hi - Lo + 1), fun(N) -> Hi - N end);
integer(Lo, Hi) -> oneof([magnitude(Hi + 1), qcheck:map(magnitude(1 - Lo), fun(N) -> -N end)]).

non_negative() -> sized(fun(Size) -> magnitude(1 bsl (8 * (Size + 1))) end).
magnitude(Max) when Max =< 16#100000000 -> qcheck:bounded_int(0, Max - 1);
magnitude(Max) ->
    Limbs = vector(limb_count(Max - 1), qcheck:bounded_int(0, 16#ffff)),
    qcheck:map(Limbs, fun(Values) ->
        lists:foldl(fun(Limb, N) -> (N bsl 16) bor Limb end, 0, Values) rem Max
    end).
limb_count(0) -> 0;
limb_count(N) -> 1 + limb_count(N bsr 16).

%% The framework has no max-shrinks option. Stop yielding native candidates
%% after the budget, across siblings and descendants of the entire tree.
limit(Type, Maximum) -> {generator, fun(Seed) ->
    {Tree, Next} = qcheck:generate_tree(Type, Seed),
    put({?MODULE, remaining}, Maximum),
    {limit_tree(Tree), Next}
end}.
limit_tree({tree, Value, Children}) ->
    {tree, Value, 'gleam@yielder':unfold(Children, fun(Rest) ->
        case setting(remaining, 0) of
            0 -> done;
            N -> case 'gleam@yielder':step(Rest) of
                done -> done;
                {next, Child, Tail} ->
                    put({?MODULE, remaining}, N - 1),
                    {next, limit_tree(Child), Tail}
            end
        end
    end)}.

setting(Key, Default) -> case get({?MODULE, Key}) of undefined -> Default; Value -> Value end.

%% ref:DEC-never-pass-vacuously ref:DEC-portable-seeded-generation
check(Label, {Type, Predicate}, Options) ->
    Seed = case os:getenv("LAWSPEC_SEED") of
        false -> erlang:system_time(nanosecond) bxor erlang:unique_integer([positive]);
        Text -> list_to_integer(Text)
    end,
    Keys = [attempts, remaining, failure],
    Previous = [{K, erase({?MODULE, K})} || K <- Keys],
    put({?MODULE, attempts}, proplists:get_value(constraint_tries, Options, 100)),
    try
        lawspec_beam_generators:with_cache(fun() ->
            Config = qcheck:config(proplists:get_value(numtests, Options, 100), 1, qcheck:seed(Seed)),
            qcheck:run(Config, limit(Type, proplists:get_value(max_shrinks, Options, 1000)), fun(Value) ->
                try
                    case Predicate(Value) of
                        true -> nil;
                        false -> erlang:error({lawspec, false_property});
                        Other -> erlang:error({lawspec, {non_boolean_property, Other}})
                    end
                catch Kind:Reason:Stack ->
                    put({?MODULE, failure}, {counterexample, Value, Kind, Reason}),
                    erlang:raise(Kind, Reason, Stack)
                end
            end),
            ok
        end)
    catch Kind:Reason:Stack ->
        erlang:raise(error, {lawspec, {property_failed, Label, {seed, Seed},
            {Kind, Reason}, setting(failure, none)}}, Stack)
    after
        lists:foreach(fun({K, undefined}) -> erase({?MODULE, K});
            ({K, V}) -> put({?MODULE, K}, V) end, Previous)
    end.
