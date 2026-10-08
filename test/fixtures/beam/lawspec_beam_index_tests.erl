%% @doc The same indexed domains run in all three native property frameworks.
%% ref:DEC-tests-cite-requirements ref:DEC-gadts-and-index-arithmetic
-module(lawspec_beam_index_tests).
-export([run/1]).
-include_lib("eunit/include/eunit.hrl").

run(F) ->
    Row = type(<<"Row">>), Perfect = type(<<"Perfect">>),
    Definitions = [
        definition(<<"Row">>, [
            constructor(<<"End">>, [], [<<"c0">>]),
            constructor(<<"Cell">>, [type(<<"Int32">>), Row], [<<"+ f1 c1">>]),
            %% A recursive branch with the same index must still terminate.
            constructor(<<"Wrap">>, [Row], [<<"f0">>])]),
        definition(<<"Perfect">>, [
            constructor(<<"Leaf">>, [type(<<"Int32">>)], [<<"c0">>]),
            constructor(<<"Node">>, [Perfect, Perfect], [<<"+ f0 c1">>, <<"== f0 f1">>])]),
        definition(<<"Grid">>, [constructor(<<"Grid">>, [Row, Row], [<<"* f0 f1">>])]),
        definition(<<"Pairs">>, [constructor(<<"Pairs">>, [Row], [<<"div f0 c2">>])]),
        definition(<<"Rest">>, [constructor(<<"Rest">>, [Row], [<<"- f0 c1">>, <<">= f0 c1">>])]),
        definition(<<"Mod">>, [constructor(<<"Mod">>, [Row], [<<"mod f0 c3">>])]),
        definition(<<"Power">>, [constructor(<<"Power">>, [Row], [<<"^ f0 c2">>])]),
        definition(<<"Shown">>, [(constructor(<<"Shown">>, [{parameter, 0}, type(<<"Text">>)], []))#{
            existentials => 1, witnesses => [0]}])
    ],
    S = lawspec_beam_schema:new(Definitions, [<<"Int32">>, <<"Bool">>, <<"Text">>], 64),
    Equations = maps:from_list([{maps:get(tag, C), maps:get(indices, C)} || D <- Definitions,
        C <- maps:get(constructors, D), maps:get(indices, C) =/= []]),
    lists:foreach(fun({Name, K}) ->
        T = type(Name),
        G = F:generator(T, S, make_ref(), [], [], {K, Equations}),
        ok = check(F, G, fun(V) ->
            ?assertEqual(V, lawspec_beam_schema:validate(V, T, S)),
            Index = lawspec_beam_schema:index(V, T, 0, S),
            ?assert(case K of -1 -> Index >= 0 andalso Index =< 5; _ -> Index =:= K end),
            ?assert(node_count(V) =< max(101, 2 * K + 1)),
            true
        end),
        ?assertEqual(undefined, get({lawspec_beam_index, tables}))
    end, [{<<"Row">>, 7}, {<<"Row">>, 80}, {<<"Perfect">>, 3}, {<<"Perfect">>, -1},
        {<<"Grid">>, 12}, {<<"Pairs">>, 2}, {<<"Rest">>, 3}, {<<"Mod">>, 1}, {<<"Power">>, 9}]),
    %% An unavailable dependent index retries the entire prefix, so this
    %% property only has a single inhabited tuple: a square of index one.
    Dependent = F:complete(F:bind(F:integer(1, 2), fun(K) ->
        F:bind(F:generator(type(<<"Power">>), S, make_ref(), [], [], {K, Equations}),
            fun(V) -> [K, V] end)
    end)),
    ?assertEqual(ok, check(F, Dependent, fun([K, _]) -> K =:= 1 end)),
    Shown = F:generator(type(<<"Shown">>), S, make_ref(), [], []),
    ok = check(F, Shown, fun({ls_data, <<"Shown">>, [Value, Witness]} = V) ->
        ?assertEqual(V, lawspec_beam_schema:validate(V, type(<<"Shown">>), S)),
        ?assert(case Witness of <<"Bool">> -> is_boolean(Value); <<"Int32">> -> is_integer(Value) end),
        true
    end),
    %% A deliberately false property exercises each framework's shrink walk.
    %% Every attempted counterexample must retain the requested index.
    Indexed = F:generator(Row, S, make_ref(), [], [], {3, Equations}),
    put({?MODULE, shrinks}, []),
    try
        Result = try check(F, Indexed, fun(V) ->
            Valid = try V =:= lawspec_beam_schema:validate(V, Row, S) andalso
                lawspec_beam_schema:index(V, Row, 0, S) =:= 3 catch _:_ -> false end,
            put({?MODULE, shrinks}, [Valid | get({?MODULE, shrinks})]),
            false
        end) of _ -> escaped catch error:{lawspec, _} -> failed end,
        ?assertEqual(failed, Result),
        Seen = get({?MODULE, shrinks}),
        ?assert(length(Seen) > 1),
        ?assert(lists:all(fun(V) -> V end, Seen))
    after erase({?MODULE, shrinks}) end,
    ok.

check(F, G, Predicate) -> F:check(<<"indexed generation">>, F:forall(G, Predicate),
    [quiet, {numtests, 100}, {max_shrinks, 1000}, {constraint_tries, 100}]).
type(Name) -> {Name, []}.
definition(Name, Cs) -> #{name => Name, parameters => 0, constructors => Cs}.
constructor(Tag, Types, Indices) -> #{tag => Tag, native_tag => value,
    fields => [{integer_to_binary(I), T} || {I, T} <- lists:enumerate(Types)], indices => Indices}.
node_count({ls_data, _, Values}) -> 1 + lists:sum([node_count(V) || V <- Values]);
node_count(_) -> 1.
