%% @doc Test the actual framework's generation, constraints and shrink results.
%% ref:DEC-native-property-frameworks ref:DEC-tests-cite-requirements
-module(lawspec_beam_proper_tests).
-include_lib("eunit/include/eunit.hrl").

schema() -> lawspec_beam_schema:new([], [<<"Int32">>, <<"Text">>, <<"Symbol">>], 64).
integer(Lo, Hi) -> lawspec_beam_proper:generator({<<"Int32">>, []}, schema(), make_ref(),
    [{<<">=">>, Lo}, {<<"<=">>, Hi}], []).

indexed_and_existential_generation_test_() ->
    {timeout, 60, fun() -> lawspec_beam_index_tests:run(lawspec_beam_proper) end}.

native_factories_keep_checked_shrinks_test() -> lawspec_beam_native_generator_tests:run(lawspec_beam_proper).

%% ref:DEC-shrink-within-domain
bounded_shrinking_test() ->
    Property = proper:forall(integer(5, 1000), fun(N) -> N < 5 end),
    ?assertEqual(false, proper:quickcheck(Property, [quiet, {numtests, 30}])),
    ?assertEqual([5], proper:counterexample()).

%% ref:DEC-shrink-within-domain
dependent_shrinking_test() ->
    Generator = lawspec_beam_proper:bind(integer(0, 100), fun(X) ->
        lawspec_beam_proper:bind(integer(X + 1, X + 10), fun(Y) -> [X, Y] end)
    end),
    ?assert(proper:quickcheck(proper:forall(Generator, fun([X, Y]) ->
        X >= 0 andalso Y > X andalso Y =< X + 10
    end), [quiet, {numtests, 1000}])),
    ?assertEqual(false, proper:quickcheck(proper:forall(Generator, fun([X, Y]) ->
        Y =< X
    end), [quiet])),
    ?assertEqual([[0, 1]], proper:counterexample()).

%% ref:DEC-never-pass-vacuously
impossible_domain_fails_test() ->
    Generator = lawspec_beam_proper:constrain(integer(0, 0), fun(_) -> false end),
    ?assertMatch({error, _}, proper:quickcheck(proper:forall(Generator, fun(_) -> true end),
        [quiet, {constraint_tries, 3}])).

%% ref:DEC-shrink-within-domain
empty_dependent_range_retries_tuple_test() ->
    Generator = lawspec_beam_proper:complete(lawspec_beam_proper:bind(integer(0, 1), fun(X) ->
        lawspec_beam_proper:bind(integer(X + 1, 1), fun(Y) -> [X, Y] end)
    end)),
    ?assert(proper:quickcheck(proper:forall(Generator, fun(Pair) -> Pair =:= [0, 1] end),
        [quiet, {numtests, 1000}])),
    Empty = lawspec_beam_proper:complete(integer(2, 1)),
    ?assertMatch({error, _}, proper:quickcheck(proper:forall(Empty, fun(_) -> true end),
        [quiet, {constraint_tries, 3}])).

%% ref:DEC-shrink-within-domain
dependent_predicate_retries_prefix_test() ->
    Generator = lawspec_beam_proper:complete(lawspec_beam_proper:bind(integer(0, 1), fun(X) ->
        lawspec_beam_proper:bind(lawspec_beam_proper:refine_input(integer(0, 1), fun(Y) -> Y > X end),
            fun(Y) -> [X, Y] end)
    end)),
    ?assert(proper:quickcheck(proper:forall(Generator, fun(Pair) -> Pair =:= [0, 1] end),
        [quiet, {numtests, 1000}])),
    ?assertEqual(false, proper:quickcheck(proper:forall(Generator, fun(_) -> false end), [quiet])),
    ?assertEqual([[0, 1]], proper:counterexample()).

%% ref:DEC-structural-size-budget
recursive_generation_test() ->
    Tree = {<<"Tree">>, []},
    Schema = lawspec_beam_schema:new([#{name => <<"Tree">>, parameters => 0,
        constructors => [
            #{tag => <<"Tree::Leaf">>, native_tag => leaf, fields => [{<<"value">>, {<<"Int32">>, []}}]},
            #{tag => <<"Tree::Fork">>, native_tag => fork, fields => [{<<"left">>, Tree}, {<<"right">>, Tree}]}
        ]}], [<<"Int32">>], 32),
    Generator = lawspec_beam_proper:generator(Tree, Schema, make_ref(), [], []),
    ?assert(proper:quickcheck(proper:forall(Generator, fun(Value) ->
        Value =:= lawspec_beam_schema:validate(Value, Tree, Schema) andalso node_count(Value) =< 33
    end), [quiet, {numtests, 1000}, {max_size, 32}])).
node_count({ls_data, _, Values}) -> 1 + lists:sum([node_count(V) || V <- Values]);
node_count(_) -> 1.

%% ref:DEC-structural-size-budget
large_witness_sets_the_structural_budget_test() ->
    Names = [integer_to_binary(I) || I <- lists:seq(1, 65)],
    Types = lists:zip(Names, tl(Names) ++ [<<"Int32">>]),
    Definitions = [#{name => N, parameters => 0, constructors => [#{tag => N,
        native_tag => box, fields => [{<<"value">>, {Child, []}}]}]} || {N, Child} <- Types],
    Schema = lawspec_beam_schema:new(Definitions, [<<"Int32">>], 64),
    Witness = lists:foldr(fun(N, V) -> {ls_data, N, [V]} end, 0, Names),
    Type = {hd(Names), []},
    Generator = lawspec_beam_proper:generator(Type, Schema, make_ref(), [], [Witness]),
    ?assertEqual(ok, lawspec_beam_proper:check(<<"deep data">>, proper:forall(Generator,
        fun(V) -> V =:= lawspec_beam_schema:validate(V, Type, Schema) end),
        [quiet, {numtests, 10}])).

%% ref:DEC-portable-exact-arithmetic
symbols_do_not_alias_literals_test() ->
    Symbols = make_ref(),
    Literal = lawspec_beam_scalar:literal(#{<<"type">> => <<"Symbol">>, <<"id">> => <<"0">>, <<"description">> => <<"0">>}, Symbols),
    Generator = lawspec_beam_proper:generator({<<"Symbol">>, []}, schema(), Symbols, [], []),
    ?assert(proper:quickcheck(proper:forall(Generator, fun(Value) ->
        not lawspec_beam_scalar:equal(Value, Literal)
    end), [quiet, {numtests, 1000}])).

%% ref:DEC-never-pass-vacuously
reported_failures_retain_replay_seed_test() ->
    Previous = os:getenv("LAWSPEC_SEED"),
    true = os:putenv("LAWSPEC_SEED", "2026"),
    try
        ?assertError({lawspec, {property_failed, <<"bad">>, {seed, 2026}, false}},
            lawspec_beam_proper:check(<<"bad">>, proper:forall(integer(5, 10), fun(_) -> false end), [quiet]))
    after
        case Previous of false -> os:unsetenv("LAWSPEC_SEED"); _ -> os:putenv("LAWSPEC_SEED", Previous) end
    end.
