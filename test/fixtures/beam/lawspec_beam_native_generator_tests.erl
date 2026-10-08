%% @doc Native factories keep the framework's trees and checked crossings.
%% ref:DEC-native-bindings-typed-identity ref:DEC-shrink-within-domain
-module(lawspec_beam_native_generator_tests).
-export([run/1]).
-include_lib("eunit/include/eunit.hrl").

run(F) ->
    Int = {<<"Int8">>, []}, Box = {<<"Box">>, [Int]}, Row = {<<"Row">>, []}, Outer = {<<"Outer">>, []},
    S = lawspec_beam_schema:new([
        #{name => <<"Box">>, parameters => 1, constructors => [
            #{tag => <<"Box">>, native_tag => box, fields => [{<<"item">>, {parameter, 0}}]}]},
        #{name => <<"Empty">>, parameters => 0, constructors => []},
        #{name => <<"Phantom">>, parameters => 1, constructors => [
            #{tag => <<"Phantom">>, native_tag => phantom, fields => []}]},
        #{name => <<"Row">>, parameters => 0, constructors => [
            #{tag => <<"End">>, native_tag => row_end, fields => [], indices => [<<"c0">>]},
            #{tag => <<"More">>, native_tag => row_more, fields => [{<<"item">>, Int}, {<<"tail">>, Row}], indices => [<<"+ f1 c1">>]}]},
        #{name => <<"Outer">>, parameters => 0, constructors => [
            #{tag => <<"Outer">>, native_tag => outer, fields => [{<<"row">>, Row}], indices => [<<"f0">>]}]}
    ], [<<"Int8">>], 64),
    Native = lawspec_beam_schema:with_bindings(S, #{<<"Box">> => #{native_tag => wrapped}}, #{}),
    Factories = #{<<"Int8">> => fun([]) -> F:integer(10, 100) end,
        <<"Box">> => fun([Child]) -> F:map(Child, fun(V) -> {wrapped, V} end) end,
        <<"Phantom">> => fun([_Unused]) -> F:exactly(phantom) end},
    Bound = lawspec_beam_generators:with_native(S, Native, Factories),
    G = F:generator(Box, Bound, make_ref(), [], [{ls_data, <<"Box">>, [0]}]),
    ok = check(F, G, fun({ls_data, <<"Box">>, [N]}) -> N >= 10 andalso N =< 100 end),
    Nested = F:generator({<<"Maybe">>, [Box]}, Bound, make_ref(), [], []),
    ok = check(F, Nested, fun
        ({ls_data, <<"Maybe::Nothing">>, []}) -> true;
        ({ls_data, <<"Maybe::Just">>, [{ls_data, <<"Box">>, [N]}]}) -> N >= 10 andalso N =< 100
    end),
    Phantom = F:generator({<<"Phantom">>, [{<<"Empty">>, []}]}, Bound, make_ref(), [], []),
    ok = check(F, Phantom, fun(V) -> V =:= {ls_data, <<"Phantom">>, []} end),
    Refined = F:complete(F:generator(Int, Bound, make_ref(), [{<<">">>, 50}], [])),
    ok = check(F, Refined, fun(N) -> N > 50 andalso N =< 100 end),
    %% Directed construction must retain custom factories in indexed children.
    Rows = lawspec_beam_generators:with_native(S, Native, Factories#{<<"Row">> =>
        fun([]) -> F:oneof([F:exactly({row_more, 120, {row_more, 120, row_end}}), F:exactly({row_more, 120, row_end})]) end}),
    Equations = #{<<"End">> => [<<"c0">>], <<"More">> => [<<"+ f1 c1">>], <<"Outer">> => [<<"f0">>]},
    Indexed = F:complete(F:generator(Outer, Rows, make_ref(), [], [], {2, Equations})),
    ok = check(F, Indexed, fun({ls_data, <<"Outer">>, [V]}) ->
        V =:= {ls_data, <<"More">>, [120, {ls_data, <<"More">>, [120, {ls_data, <<"End">>, []}]}]}
    end),
    %% A controlled native tree proves that the supplied shrink is retained.
    Tree = tree(F, 50, [10]),
    Shrinking = lawspec_beam_generators:with_native(S, Native, Factories#{<<"Int8">> => fun([]) -> Tree end}),
    put({?MODULE, seen}, []),
    failure(fun() -> check(F, F:generator(Box, Shrinking, make_ref(), [], []), fun({ls_data, _, [N]}) ->
        put({?MODULE, seen}, [N | get({?MODULE, seen})]), false
    end) end),
    Seen = erase({?MODULE, seen}),
    ?assert(lists:member(50, Seen)),
    ?assert(lists:member(10, Seen)),
    %% Neither malformed factories nor invalid samples are filter rejections.
    lists:foreach(fun(Factory) ->
        Bad = lawspec_beam_generators:with_native(S, Native, #{<<"Int8">> => Factory}),
        failure(fun() -> check(F, F:generator(Int, Bad, make_ref(), [], [0]), fun(_) -> true end) end)
    end, [fun([]) -> not_a_generator end, fun([]) -> F:exactly(128) end,
          fun([]) -> F:constrain(F:exactly(10), fun(_) -> false end) end]),
    %% An out-of-domain shrink must raise a checked-boundary error, not be
    %% silently pruned by the framework or reach the property predicate.
    BadTree = tree(F, 50, [128]),
    InvalidShrink = lawspec_beam_generators:with_native(S, Native, #{<<"Int8">> => fun([]) -> BadTree end}),
    try check(F, F:generator(Int, InvalidShrink, make_ref(), [], []), fun(V) ->
        ?assertEqual(50, V), false
    end) of
        _ -> ?assert(false)
    catch
        error:{lawspec, {<<"native generator Int8">>, _}} -> ok;
        error:{lawspec, Reason} ->
            ?assertNotEqual(nomatch, string:find(lists:flatten(io_lib:format("~p", [Reason])), "native generator Int8"))
    end,
    ok.

check(F, G, Predicate) -> F:check(<<"native generators">>, F:forall(G, Predicate),
    [quiet, {numtests, 100}, {max_shrinks, 100}, {constraint_tries, 100}]).
failure(Run) ->
    Result = try Run() of _ -> escaped catch _:_ -> failed end,
    ?assertEqual(failed, Result).

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
