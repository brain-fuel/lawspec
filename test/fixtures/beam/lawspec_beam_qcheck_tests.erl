%% @doc Tests against qcheck itself, including its public generator/shrink trees.
%% ref:DEC-native-property-frameworks ref:DEC-tests-cite-requirements
-module(lawspec_beam_qcheck_tests).
-include_lib("eunit/include/eunit.hrl").

indexed_and_existential_generation_test_() ->
    {timeout, 60, fun() -> lawspec_beam_index_tests:run(lawspec_beam_qcheck) end}.

native_factories_keep_checked_shrinks_test() -> lawspec_beam_native_generator_tests:run(lawspec_beam_qcheck).

strategy_draws_test_() -> lawspec_beam_strategy_tests:tests(lawspec_beam_qcheck).

harness_adequacy_test_() -> lawspec_beam_harness_tests:tests(lawspec_beam_qcheck).

failure_inputs_test_() -> lawspec_beam_failure_inputs_tests:tests(lawspec_beam_qcheck).

bounded_shrinking_test() ->
    Failure = failure(lawspec_beam_qcheck:integer(5, 1000), fun(_) -> false end, 1000),
    ?assertMatch({counterexample, 5, error, _}, Failure).

dependent_shrinking_test() ->
    G = lawspec_beam_qcheck:bind(lawspec_beam_qcheck:integer(0, 100), fun(X) ->
        lawspec_beam_qcheck:bind(lawspec_beam_qcheck:integer(X + 1, X + 10), fun(Y) -> [X, Y] end)
    end),
    ?assertMatch({counterexample, [0, 1], error, _}, failure(G, fun([X, Y]) ->
        ?assert(Y > X), false
    end, 1000)).

empty_dependent_range_test() ->
    G = lawspec_beam_qcheck:complete(lawspec_beam_qcheck:bind(lawspec_beam_qcheck:integer(0, 1), fun(X) ->
        lawspec_beam_qcheck:bind(lawspec_beam_qcheck:integer(X + 1, 1), fun(Y) -> [X, Y] end)
    end)),
    ?assertEqual(ok, run(G, fun(V) -> V =:= [0, 1] end, 1000)),
    ?assertMatch({counterexample, [0, 1], error, _}, failure(G, fun(_) -> false end, 1000)).

dependent_predicate_test() ->
    G = lawspec_beam_qcheck:complete(lawspec_beam_qcheck:bind(lawspec_beam_qcheck:integer(0, 1), fun(X) ->
        lawspec_beam_qcheck:bind(lawspec_beam_qcheck:refine_input(lawspec_beam_qcheck:integer(0, 1),
            fun(Y) -> Y > X end), fun(Y) -> [X, Y] end)
    end)),
    ?assertEqual(ok, run(G, fun(V) -> V =:= [0, 1] end, 1000)).

impossible_domain_fails_test() ->
    G = lawspec_beam_qcheck:complete(lawspec_beam_qcheck:integer(2, 1)),
    try run(G, fun(_) -> true end, 100) of _ -> ?assert(false)
    catch error:{lawspec, {property_failed, _, _, {error, {lawspec, exhausted_generator_attempts}}, none}} -> ok end.

wide_values_keep_high_bits_test() ->
    {Values, _} = qcheck:generate(lawspec_beam_qcheck:integer(0, (1 bsl 64) - 1), 100, qcheck:seed(42)),
    ?assert(lists:any(fun(N) -> N > 1 bsl 53 end, Values)),
    ?assert(lists:all(fun(N) -> N >= 0 andalso N < 1 bsl 64 end, Values)).

negative_wide_shrinking_test() ->
    G = lawspec_beam_qcheck:integer(-(1 bsl 128), -5),
    ?assertMatch({counterexample, -5, error, _}, failure(G, fun(_) -> false end, 1000)).

zero_shrink_budget_test() ->
    put(callbacks, 0),
    _ = failure(lawspec_beam_qcheck:integer(5, 1000), fun(_) ->
        put(callbacks, get(callbacks) + 1), false
    end, 0),
    ?assertEqual(1, erase(callbacks)).

%% ref:DEC-structural-size-budget
recursive_budget_test() ->
    Type = {<<"Tree">>, []},
    Schema = lawspec_beam_schema:new([#{name => <<"Tree">>, parameters => 0, constructors => [
        #{tag => <<"Leaf">>, native_tag => leaf, fields => [{<<"value">>, {<<"Int8">>, []}}]},
        #{tag => <<"Fork">>, native_tag => fork, fields => [{<<"left">>, Type}, {<<"right">>, Type}]}
    ]}], [<<"Int8">>], 64),
    G = lawspec_beam_qcheck:generator(Type, Schema, make_ref(), [], []),
    ?assertEqual(ok, run(G, fun(V) -> V =:= lawspec_beam_schema:validate(V, Type, Schema)
        andalso node_count(V) =< 101 end, 1000)).
node_count({ls_data, _, Values}) -> 1 + lists:sum([node_count(V) || V <- Values]);
node_count(_) -> 1.

large_witness_budget_test() ->
    Names = [integer_to_binary(I) || I <- lists:seq(1, 65)],
    Definitions = [#{name => N, parameters => 0, constructors => [#{tag => N,
        native_tag => box, fields => [{<<"value">>, {Child, []}}]}]} || {N, Child} <- lists:zip(Names, tl(Names) ++ [<<"Int8">>])],
    Schema = lawspec_beam_schema:new(Definitions, [<<"Int8">>], 64),
    Witness = lists:foldr(fun(N, V) -> {ls_data, N, [V]} end, 0, Names),
    Type = {hd(Names), []},
    G = lawspec_beam_qcheck:generator(Type, Schema, make_ref(), [], [Witness]),
    ?assertEqual(ok, run(G, fun(V) -> V =:= lawspec_beam_schema:validate(V, Type, Schema) end, 100)).

generated_symbols_do_not_alias_literals_test() ->
    Symbols = make_ref(),
    Schema = lawspec_beam_schema:new([], [<<"Symbol">>], 64),
    Literal = lawspec_beam_scalar:literal(#{<<"type">> => <<"Symbol">>, <<"id">> => <<"0">>, <<"description">> => <<"0">>}, Symbols),
    G = lawspec_beam_qcheck:generator({<<"Symbol">>, []}, Schema, Symbols, [], []),
    ?assertEqual(ok, run(G, fun(V) -> not lawspec_beam_scalar:equal(V, Literal) end, 100)).

decimal_exponents_follow_framework_size_test() ->
    Schema = lawspec_beam_schema:new([], [<<"Decimal">>], 64),
    G = lawspec_beam_qcheck:generator({<<"Decimal">>, []}, Schema, make_ref(), [], []),
    ?assertEqual(ok, run(G, fun({ls_decimal, _, E} = V) ->
        abs(E) =< 100 andalso lawspec_beam_scalar:equal(V, V)
    end, 100)).

run(Generator, Predicate, Shrinks) ->
    lawspec_beam_qcheck:check(<<"qcheck test">>, lawspec_beam_qcheck:forall(Generator, Predicate),
        [{numtests, 100}, {max_shrinks, Shrinks}, {constraint_tries, 100}]).
failure(Generator, Predicate, Shrinks) ->
    Previous = os:getenv("LAWSPEC_SEED"), os:putenv("LAWSPEC_SEED", "42"),
    try run(Generator, Predicate, Shrinks) of _ -> ?assert(false)
    catch error:{lawspec, {property_failed, _, {seed, 42}, _, Counterexample}} -> Counterexample
    after
        ?assertEqual(undefined, get({lawspec_beam_qcheck, failure})),
        ?assertEqual(undefined, get({lawspec_beam_qcheck, remaining})),
        ?assertEqual(undefined, get({lawspec_beam_qcheck, attempts})),
        case Previous of false -> os:unsetenv("LAWSPEC_SEED"); _ -> os:putenv("LAWSPEC_SEED", Previous) end
    end.
