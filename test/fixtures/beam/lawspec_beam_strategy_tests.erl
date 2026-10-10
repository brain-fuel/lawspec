%% @doc Harness strategies use each framework's generation and shrinking.
%% ref:REQ-harness-units ref:DEC-native-property-frameworks ref:DEC-tests-cite-requirements
-module(lawspec_beam_strategy_tests).
-export([tests/1, run/1]).
-include_lib("eunit/include/eunit.hrl").

tests(F) -> [
    {"discard limits count rejected root draws", fun() -> discard_limits(F) end},
    {"nested discard limits remain independent", fun() -> nested_limits(F) end},
    {"filtered native shrink trees retain valid children", fun() -> native_tree(F) end},
    {"native shrinking preserves dependent filters", fun() -> dependent_shrinks(F) end},
    {"invalid strategy samples fail before tuple retry", fun() -> invalid_sample(F) end},
    {"invalid strategy shrinks fail instead of being discarded", fun() -> invalid_shrink(F) end},
    {"empty dependent domains still retry their prefix", fun() -> empty_domain(F) end},
    {"the reported seed replays filtered dependent draws", fun() -> replay(F) end},
    {"length refinements generate at native size zero", fun() -> lengths(F) end},
    {"length refinements retain native element and length shrinks", fun() -> length_shrinks(F) end},
    {"dependent length refinements redraw impossible prefixes", fun() -> dependent_lengths(F) end},
    {"named symbol hints retain fixture identity", fun() -> symbols(F) end},
    {"empty length domains fail before any property callback", fun() -> empty_lengths(F) end},
    {"wrapper fields generate within their contracts", fun() -> wrapper_fields(F) end},
    {"dependent field generators retain earlier shrunk fields", fun() -> dependent_fields(F) end},
    {"set and map native shrink trees stay canonical", fun() -> collections(F) end}
].
run(F) -> lists:foreach(fun({_Name, Test}) -> Test() end, tests(F)), ok.

discard_limits(F) ->
    lists:foreach(fun(Limit) ->
        put(strategy_draws, 0),
        Raw = counted(F),
        Filtered = F:such_that(Raw, fun(_) -> false end, Limit, <<"never">>),
        Reason = failure(F, Filtered, fun(_) -> true end),
        ?assertEqual(Limit + 1, erase(strategy_draws)),
        ?assert(contains({strategy_discards, <<"never">>, Limit}, Reason)),
        ?assert(contains({seed, 42}, Reason))
    end, [0, 1, 3]),
    put(strategy_draws, 0),
    %% A zero budget still permits the first successful draw.
    ok = check(F, F:such_that(counted(F), fun(_) -> true end, 0, <<"first">>), fun(_) -> true end),
    ?assertEqual(1, erase(strategy_draws)).

nested_limits(F) ->
    put(strategy_draws, 0),
    Inner = F:such_that(counted(F), fun(N) -> N >= 3 end, 2, <<"inner">>),
    Outer = F:such_that(Inner, fun(_) -> true end, 0, <<"outer">>),
    ok = check(F, Outer, fun(N) -> N =:= 3 end),
    ?assertEqual(3, erase(strategy_draws)),
    put(strategy_draws, 0),
    Never = F:such_that(counted(F), fun(_) -> false end, 2, <<"inner">>),
    Reason = failure(F, F:such_that(Never, fun(_) -> true end, 50, <<"outer">>), fun(_) -> true end),
    ?assertEqual(3, erase(strategy_draws)),
    ?assert(contains({strategy_discards, <<"inner">>, 2}, Reason)),
    ?assertNot(contains({strategy_discards, <<"outer">>, 50}, Reason)),
    %% A failed native source is not this outer filter rejecting a value.
    Source = F:constrain(F:exactly(0), fun(_) -> false end),
    SourceReason = failure(F, F:such_that(Source, fun(_) -> true end, 0, <<"outer">>), fun(_) -> true end),
    ?assertNot(contains({strategy_discards, <<"outer">>, 0}, SourceReason)).

native_tree(F) ->
    put(strategy_seen, []),
    Filtered = F:such_that(tree(F, 50, [0, 10]), fun(N) -> N >= 5 end, 0, <<"positive">>),
    _ = failure(F, Filtered, fun record_failure/1),
    Seen = erase(strategy_seen),
    ?assert(lists:member(50, Seen)),
    ?assert(lists:member(10, Seen)),
    ?assertNot(lists:member(0, Seen)).

dependent_shrinks(F) ->
    put(strategy_seen, []),
    Pair = F:bind(F:integer(0, 100), fun(X) ->
        F:bind(F:integer(X + 1, X + 10), fun(Y) -> [X, Y] end)
    end),
    Valid = fun([X, Y]) -> X >= 5 andalso Y > X andalso Y =< X + 10 end,
    Filtered = F:such_that(Pair, Valid, 1000, <<"pairs">>),
    _ = failure(F, Filtered, fun record_failure/1),
    Seen = erase(strategy_seen),
    ?assert(lists:all(Valid, Seen)),
    ?assert(lists:member([5, 6], Seen)),
    ?assert(lists:any(fun(V) -> V =/= [5, 6] end, Seen)).

invalid_sample(F) ->
    put(strategy_draws, 0),
    Drawn = checked(F, counted(F), fun(N) -> N > 1 end),
    %% A later default input may discard the tuple, but cannot conceal an
    %% invalid explicit strategy sample by causing the earlier input to retry.
    Generator = F:complete(F:bind(Drawn, fun(_) -> F:exactly('$lawspec_empty_domain') end)),
    Reason = failure(F, Generator, fun(_) -> true end),
    ?assertEqual(1, erase(strategy_draws)),
    ?assert(contains({strategy_outside_refinement, <<"draws">>, <<"n">>, 1}, Reason)).

invalid_shrink(F) ->
    put(strategy_seen, []),
    Generator = checked(F, tree(F, 50, [4]), fun(N) -> N >= 5 end),
    Reason = failure(F, Generator, fun record_failure/1),
    ?assertEqual([50], lists:usort(erase(strategy_seen))),
    ?assert(contains({strategy_outside_refinement, <<"draws">>, <<"n">>, 4}, Reason)).

empty_domain(F) ->
    Empty = F:such_that(F:exactly('$lawspec_empty_domain'),
        fun(_) -> erlang:error(predicate_saw_empty_domain) end, 0, <<"empty">>),
    Reason = failure(F, F:complete(Empty), fun(_) -> true end),
    ?assertNot(contains(predicate_saw_empty_domain, Reason)),
    ?assertNot(contains({strategy_discards, <<"empty">>, 0}, Reason)).

replay(F) ->
    G = F:bind(F:integer(-1000, 1000), fun(X) ->
        F:map(F:such_that(F:integer(X, X + 10), fun(Y) -> Y rem 2 =:= 0 end, 100, <<"even">>),
            fun(Y) -> [X, Y] end)
    end),
    Trace = fun(Seed) ->
        put(strategy_seen, []),
        ok = check(F, G, fun(V) -> put(strategy_seen, [V | get(strategy_seen)]), true end, Seed, 30),
        lists:reverse(erase(strategy_seen))
    end,
    First = Trace(42),
    ?assertEqual(30, length(First)),
    ?assertEqual(First, Trace(42)),
    ?assertNotEqual(First, Trace(43)),
    ?assertEqual(First, Trace(42)).

lengths(F) ->
    Types = [{<<"Bytes">>, []}, {<<"Text">>, []}, {<<"CodePointText">>, []},
        {<<"Utf16Text">>, []}, {<<"List">>, [{<<"Int8">>, []}]}],
    lists:foreach(fun({Name, _} = Type) ->
        Schema = lawspec_beam_schema:new([], [<<"Int8">>] ++ [Name || Name =/= <<"List">>], 64),
        G = F:generator(Type, Schema, make_ref(), [{length, <<"==">>, 3}], []),
        ok = check(F, size_zero(F, G), fun(V) ->
            ?assertEqual(V, lawspec_beam_schema:validate(V, Type, Schema)),
            value_length(Name, V) =:= 3
        end, 42, 100)
    end, Types).

length_shrinks(F) ->
    S = lawspec_beam_schema:new([], [<<"Bytes">>], 64),
    G = F:generator({<<"Bytes">>, []}, S, make_ref(),
        [{length, <<">=">>, 2}, {length, <<"<=">>, 4}], []),
    put(strategy_seen, []),
    _ = failure(F, G, fun(V) ->
        ?assert(byte_size(V) >= 2 andalso byte_size(V) =< 4),
        record_failure(V)
    end),
    Seen = erase(strategy_seen),
    ?assert(length(lists:usort(Seen)) > 1),
    ?assert(lists:member(<<0, 0>>, Seen)).

dependent_lengths(F) ->
    S = lawspec_beam_schema:new([], [<<"Bytes">>], 64),
    G = F:complete(F:bind(F:integer(-2, 4), fun(N) ->
        F:bind(F:generator({<<"Bytes">>, []}, S, make_ref(), [{length, <<"==">>, N}], []),
            fun(Value) -> F:exactly({N, Value}) end)
    end)),
    %% Rejected prefixes are independent of explicit strategy discard budgets.
    Previous = os:getenv("LAWSPEC_SEED"), os:putenv("LAWSPEC_SEED", "42"),
    try F:check(<<"dependent lengths">>, F:forall(G, fun({N, V}) -> N =:= byte_size(V) end),
        [quiet, {numtests, 100}, {max_shrinks, 100}, {constraint_tries, 100}])
    after restore_seed(Previous) end.

symbols(F) ->
    S = lawspec_beam_schema:new([], [<<"Symbol">>], 64),
    Context = make_ref(),
    Hint = lawspec_beam_scalar:literal(#{<<"type">> => <<"Symbol">>,
        <<"id">> => <<"selected">>, <<"description">> => <<"fixture">>}, Context),
    G = F:complete(F:refine_input(F:generator({<<"Symbol">>, []}, S, Context, [], [Hint]),
        fun(V) -> lawspec_beam_scalar:equal(V, Hint) end)),
    Previous = os:getenv("LAWSPEC_SEED"), os:putenv("LAWSPEC_SEED", "42"),
    try F:check(<<"symbol hints">>, F:forall(G, fun(V) -> V =:= Hint end),
        [quiet, {numtests, 100}, {max_shrinks, 100}, {constraint_tries, 1000}])
    after restore_seed(Previous) end.

empty_lengths(F) ->
    S = lawspec_beam_schema:new([], [<<"Bytes">>], 64),
    lists:foreach(fun(Bounds) ->
        G = F:complete(F:generator({<<"Bytes">>, []}, S, make_ref(), Bounds, [])),
        put(strategy_seen, []),
        _ = failure(F, G, fun record_failure/1),
        ?assertEqual([], erase(strategy_seen))
    end, [[{length, <<"==">>, -1}], [{length, <<">">>, 2}, {length, <<"<">>, 3}]]).

value_length(Name, V) -> lawspec_beam_scalar:helper(<<"length">>, [V], [Name], <<"Integer">>).
size_zero(lawspec_beam_proper, G) -> proper_types:resize(0, G);
size_zero('Elixir.LawSpec.Beam.StreamData', G) -> 'Elixir.StreamData':resize(G, 0);
size_zero(lawspec_beam_qcheck, G) -> G.
restore_seed(false) -> os:unsetenv("LAWSPEC_SEED");
restore_seed(Value) -> os:putenv("LAWSPEC_SEED", Value).

wrapper_fields(F) ->
    lists:foreach(fun({Name, Type, Bounds, Predicate}) ->
        S = lawspec_beam_schema:new([#{name => Name, parameters => 0, constructors => [
            #{tag => Name, native_tag => wrapped, fields => [{<<"value">>, Type}],
              generators => #{1 => fun(_, _, []) -> {Bounds, []} end},
              predicates => [fun(_, _, [V]) -> Predicate(V) end]}]}], [<<"Int32">>, <<"Bytes">>], 64),
        G = F:generator({Name, []}, S, make_ref(), [], []),
        ok = check(F, size_zero(F, G), fun({ls_data, _, [V]}) -> Predicate(V) end, 42, 100)
    end, [{<<"Positive">>, {<<"Int32">>, []}, [{<<">=">>, 1}, {<<"<=">>, 1000}], fun(N) -> N >= 1 andalso N =< 1000 end},
          {<<"NonEmpty">>, {<<"List">>, [{<<"Int32">>, []}]}, [{length, <<">">>, 0}], fun(V) -> length(V) > 0 end},
          {<<"ThreeBytes">>, {<<"Bytes">>, []}, [{length, <<"==">>, 3}], fun(V) -> byte_size(V) =:= 3 end}]).

dependent_fields(F) ->
    S = lawspec_beam_schema:new([#{name => <<"Pair">>, parameters => 0, constructors => [
        #{tag => <<"Pair">>, native_tag => pair, fields => [{<<"first">>, {<<"Int32">>, []}}, {<<"second">>, {<<"Int32">>, []}}],
          generators => #{1 => fun(_, _, []) -> {[{<<">=">>, 1}, {<<"<=">>, 10}], []} end,
              2 => fun(_, _, [X]) -> {[{<<">">>, X}, {<<"<=">>, X + 10}], []} end},
          predicates => [fun(_, _, [X, Y]) -> X >= 1 andalso X =< 10 andalso Y > X andalso Y =< X + 10 end]}]}
    ], [<<"Int32">>], 64),
    G = F:generator({<<"Pair">>, []}, S, make_ref(), [], []),
    put(strategy_seen, []),
    _ = failure(F, G, fun({ls_data, _, [X, Y]} = V) ->
        ?assert(Y > X andalso Y =< X + 10), record_failure(V)
    end),
    ?assert(lists:member({ls_data, <<"Pair">>, [1, 2]}, erase(strategy_seen))).

collections(F) ->
    Set = <<"lawspec.collections::type::Set">>, Map = <<"lawspec.collections::type::KeyVal">>, Entry = <<"Entry">>,
    P0 = {parameter, 0}, P1 = {parameter, 1}, Int = {<<"Int8">>, []},
    S = lawspec_beam_schema:new([
        #{name => Set, parameters => 1, constructors => [#{tag => Set, native_tag => set, fields => [{<<"items">>, {<<"List">>, [P0]}}]}]},
        #{name => Entry, parameters => 2, constructors => [#{tag => Entry, native_tag => entry, fields => [{<<"key">>, P0}, {<<"value">>, P1}]}]},
        #{name => Map, parameters => 2, constructors => [#{tag => Map, native_tag => key_val, fields => [{<<"entries">>, {<<"List">>, [{Entry, [P0, P1]}]}}]}]}
    ], [<<"Int8">>], 64),
    lists:foreach(fun(Type) ->
        G = F:generator(Type, S, make_ref(), [], []),
        ok = check(F, G, fun(V) -> V =:= lawspec_beam_schema:validate(V, Type, S) end, 42, 100),
        _ = failure(F, G, fun(V) ->
            ?assertEqual(V, lawspec_beam_schema:validate(V, Type, S)), false
        end)
    end, [{Set, [Int]}, {Map, [Int, Int]}, {Set, [{Set, [Int]}]}]),
    Broken = lawspec_beam_generators:with_native(S, S, #{Set => fun([_]) -> F:exactly({set, [1, 0]}) end}),
    Reason = failure(F, F:generator({Set, [Int]}, Broken, make_ref(), [], []), fun(_) -> true end),
    ?assert(contains({refinement_violation, Set}, Reason)).

counted(F) -> F:map(F:exactly(0), fun(_) ->
    Count = get(strategy_draws) + 1, put(strategy_draws, Count), Count
end).
checked(F, G, Predicate) -> F:map(G, fun(V) ->
    lawspec_beam_generators:check_drawn(<<"draws">>, <<"n">>, Predicate, V)
end).
record_failure(V) -> put(strategy_seen, [V | get(strategy_seen)]), false.

check(F, G, Predicate) -> check(F, G, Predicate, 42, 1).
check(F, G, Predicate, Seed, Runs) ->
    Previous = os:getenv("LAWSPEC_SEED"), os:putenv("LAWSPEC_SEED", integer_to_list(Seed)),
    try F:check(<<"strategies">>, F:forall(G, Predicate),
        [quiet, {numtests, Runs}, {max_shrinks, 1000}, {constraint_tries, 1}])
    after
        case Previous of false -> os:unsetenv("LAWSPEC_SEED"); _ -> os:putenv("LAWSPEC_SEED", Previous) end
    end.
failure(F, G, Predicate) ->
    Result = try check(F, G, Predicate) of _ -> escaped catch Kind:Reason -> {Kind, Reason} end,
    ?assertNotEqual(escaped, Result),
    Result.
contains(Needle, Needle) -> true;
contains(Needle, Tuple) when is_tuple(Tuple) -> contains(Needle, tuple_to_list(Tuple));
contains(Needle, Map) when is_map(Map) -> contains(Needle, maps:to_list(Map));
contains(Needle, List) when is_list(List) -> lists:any(fun(V) -> contains(Needle, V) end, List);
contains(_, _) -> false.

tree(lawspec_beam_proper, Root, Children) ->
    proper_types:shrinkwith(fun() -> Root end, fun() -> [proper_types:exactly(V) || V <- Children] end);
tree(lawspec_beam_qcheck, Root, Children) ->
    {generator, fun(Seed) -> {{tree, Root, 'gleam@yielder':from_list([
        {tree, V, 'gleam@yielder':from_list([])} || V <- Children])}, Seed} end};
tree('Elixir.LawSpec.Beam.StreamData', Root, Children) ->
    #{'__struct__' => 'Elixir.StreamData', generator => fun(_, _) ->
        #{'__struct__' => 'Elixir.StreamData.LazyTree', root => Root, children => [
            #{'__struct__' => 'Elixir.StreamData.LazyTree', root => V, children => []} || V <- Children]}
    end}.
