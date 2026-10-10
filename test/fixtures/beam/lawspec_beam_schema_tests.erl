%% @doc Native values must satisfy the same Core shapes and field contracts
%% on all three BEAM targets. ref:DEC-native-bindings-typed-identity
-module(lawspec_beam_schema_tests).
-include_lib("eunit/include/eunit.hrl").

schema(Definitions) -> lawspec_beam_schema:new(Definitions,
    [<<"Integer">>, <<"Int8">>, <<"Int32">>, <<"Bool">>, <<"Text">>,
     <<"Float64">>, <<"Rational">>, <<"Unit">>], 64).
definition(Name, Parameters, Constructors) ->
    #{name => Name, parameters => Parameters, constructors => Constructors}.
ctor(Tag, Native, Fields) -> #{tag => Tag, native_tag => Native, fields => Fields}.
box() -> definition(<<"Box">>, 1,
    [ctor(<<"Box::Box">>, box, [{<<"value">>, {parameter, 0}}])]).
box_type() -> {<<"Box">>, [{<<"Int8">>, []}]}.

%% ref:DEC-typed-core-boundary
canonical_collections_test() ->
    Set = <<"lawspec.collections::type::Set">>, Map = <<"lawspec.collections::type::KeyVal">>,
    Entry = <<"lawspec.collections::type::Entry">>,
    P0 = {parameter, 0}, P1 = {parameter, 1},
    S = schema([
        definition(Set, 1, [ctor(<<"SetItems">>, set, [{<<"items">>, {<<"List">>, [P0]}}])]),
        definition(Entry, 2, [ctor(<<"Entry">>, entry, [{<<"key">>, P0}, {<<"value">>, P1}])]),
        definition(Map, 2, [ctor(<<"KeyValEntries">>, key_val, [{<<"entries">>, {<<"List">>, [{Entry, [P0, P1]}]}}])])
    ]),
    Type = {Set, [{<<"Int8">>, []}]},
    Good = {ls_data, <<"SetItems">>, [[-1, 0, 1]]},
    ?assertEqual(Good, lawspec_beam_schema:from_native({set, [-1, 0, 1]}, Type, S)),
    lists:foreach(fun(Items) ->
        ?assertError({lawspec, {refinement_violation, Set}},
            lawspec_beam_schema:from_native({set, Items}, Type, S)),
        ?assertError({lawspec, {refinement_violation, Set}},
            lawspec_beam_schema:construct(<<"SetItems">>, [Items], Type, S))
    end, [[1, 0], [1, 1]]),
    MapType = {Map, [{<<"Rational">>, []}, {<<"Int8">>, []}]},
    Half = lawspec_beam_scalar:ratio(1, 2), Whole = lawspec_beam_scalar:ratio(1, 1),
    ?assertMatch({ls_data, <<"KeyValEntries">>, [_]},
        lawspec_beam_schema:from_native({key_val, [{entry, Half, 1}, {entry, Whole, 2}]}, MapType, S)),
    lists:foreach(fun(Entries) ->
        ?assertError({lawspec, {refinement_violation, Map}},
            lawspec_beam_schema:from_native({key_val, Entries}, MapType, S))
    end, [[{entry, Whole, 1}, {entry, Half, 2}], [{entry, Half, 1}, {entry, Half, 2}]]).

generic_bridge_test() ->
    S = schema([box()]), T = box_type(),
    Value = {ls_data, <<"Box::Box">>, [42]},
    ?assertEqual({box, 42}, lawspec_beam_schema:to_native(Value, T, S)),
    ?assertEqual(Value, lawspec_beam_schema:from_native({box, 42}, T, S)),
    ?assertError({lawspec, {integer_out_of_range, <<"Int8">>}},
        lawspec_beam_schema:from_native({box, 128}, T, S)),
    ?assertError({lawspec, {wrong_field_count, <<"Box::Box">>}},
        lawspec_beam_schema:from_native({box, 1, 2}, T, S)).

empty_record_test() ->
    S = schema([definition(<<"Seal">>, 0, [ctor(<<"Seal::Seal">>, seal, [])])]),
    V = {ls_data, <<"Seal::Seal">>, []},
    ?assertEqual(seal, lawspec_beam_schema:to_native(V, <<"Seal">>, S)),
    ?assertEqual(V, lawspec_beam_schema:from_native(seal, <<"Seal">>, S)).

elixir_struct_bridge_test() ->
    C = (ctor(<<"Box::Box">>, box, [{<<"value">>, {parameter, 0}}]))#{
        encode => fun([V]) -> #{'__struct__' => 'Elixir.Example.Box', contents => V} end,
        decode => fun
            (#{'__struct__' := 'Elixir.Example.Box', contents := V}) -> {ok, [V]};
            (_) -> no_match
        end},
    S = schema([definition(<<"Box">>, 1, [C])]),
    V = {ls_data, <<"Box::Box">>, [42]},
    Native = lawspec_beam_schema:to_native(V, box_type(), S),
    ?assertEqual(#{'__struct__' => 'Elixir.Example.Box', contents => 42}, Native),
    ?assertEqual(V, lawspec_beam_schema:from_native(Native, box_type(), S)),
    TupleSchema = lawspec_beam_schema:with_bindings(S, #{<<"Box::Box">> => #{native_tag => native_box}}, #{}),
    ?assertEqual({native_box, 42}, lawspec_beam_schema:to_native(V, box_type(), TupleSchema)),
    ?assertEqual(V, lawspec_beam_schema:from_native({native_box, 42}, box_type(), TupleSchema)).

refinement_short_circuit_test() ->
    Positive = fun(_, _, [V]) -> V > 0 end,
    Impossible = fun(_, _, _) -> erlang:error(should_not_run) end,
    C = (ctor(<<"Positive::Positive">>, positive, [{<<"value">>, {<<"Int32">>, []}}]))#{
        predicates => [Positive, Impossible]},
    S = schema([definition(<<"Positive">>, 0, [C])]),
    ?assertError({lawspec, {refinement_violation, <<"Positive::Positive">>}},
        lawspec_beam_schema:from_native({positive, -1}, <<"Positive">>, S)).

gadt_refinement_test() ->
    C = (ctor(<<"Expr::Flag">>, flag, [{<<"value">>, {<<"Bool">>, []}}]))#{
        refinements => [{0, {<<"Bool">>, []}}]},
    S = schema([definition(<<"Expr">>, 1, [C])]),
    ?assertEqual({ls_data, <<"Expr::Flag">>, [true]},
        lawspec_beam_schema:from_native({flag, true}, <<"Expr Bool">>, S)),
    ?assertError({lawspec, invalid_native_constructor},
        lawspec_beam_schema:from_native({flag, true}, <<"Expr Int32">>, S)).

existential_equation_test() ->
    C = (ctor(<<"Pack::Pack">>, pack, [{<<"value">>, {parameter, 1}}]))#{
        existentials => 1, refinements => [{0, {<<"List">>, [{parameter, 1}]}}]},
    S = schema([definition(<<"Pack">>, 1, [C])]),
    ?assertEqual({ls_data, <<"Pack::Pack">>, [7]},
        lawspec_beam_schema:from_native({pack, 7}, <<"Pack (List Int8)">>, S)),
    ?assertError({lawspec, {integer_out_of_range, <<"Int8">>}},
        lawspec_beam_schema:from_native({pack, 128}, <<"Pack (List Int8)">>, S)).

witnessed_existential_test() ->
    C = (ctor(<<"Some::Some">>, some, [{<<"value">>, {parameter, 0}},
        {<<"witness">>, {<<"Text">>, []}}]))#{existentials => 1, witnesses => [0]},
    S = schema([definition(<<"Some">>, 0, [C])]),
    ?assertEqual({ls_data, <<"Some::Some">>, [true, <<"Bool">>]},
        lawspec_beam_schema:from_native({some, true, <<"Bool">>}, <<"Some">>, S)),
    ?assertError({lawspec, {invalid_value, <<"Bool">>}},
        lawspec_beam_schema:from_native({some, 1, <<"Bool">>}, <<"Some">>, S)),
    ?assertError({lawspec, {unknown_type_or_arity, <<"Unknown">>}},
        lawspec_beam_schema:from_native({some, 1, <<"Unknown">>}, <<"Some">>, S)).

witness_instances_keep_independent_types_test() ->
    C = (ctor(<<"Two::Two">>, two, [{<<"first">>, {parameter, 0}},
        {<<"second">>, {parameter, 1}}, {<<"first_type">>, {<<"Text">>, []}},
        {<<"second_type">>, {<<"Text">>, []}}]))#{existentials => 2, witnesses => [0, 1]},
    Instances = lawspec_beam_schema:witness_instances(C),
    ?assertEqual(4, length(Instances)),
    lists:foreach(fun(#{fields := Fields, witness_values := Types}) ->
        ?assertEqual(Types, [lawspec_beam_schema:type_key(T) || {_, T} <- Fields])
    end, Instances).

index_guards_test() ->
    Zero = (ctor(<<"Nat::Zero">>, zero, []))#{indices => [<<"c0">>]},
    Succ = (ctor(<<"Nat::Succ">>, succ, [{<<"prior">>, {<<"Nat">>, []}}]))#{
        indices => [<<"+ c1 f0">>]},
    Pair = (ctor(<<"Same::Same">>, same,
        [{<<"left">>, {<<"Nat">>, []}}, {<<"right">>, {<<"Nat">>, []}}]))#{
        indices => [<<"f0">>, <<"== f0 f1">>]},
    S = schema([definition(<<"Nat">>, 0, [Zero, Succ]), definition(<<"Same">>, 0, [Pair])]),
    Two = lawspec_beam_schema:from_native({succ, {succ, zero}}, <<"Nat">>, S),
    ?assertEqual(2, lawspec_beam_schema:index(Two, <<"Nat">>, 0, S)),
    _ = lawspec_beam_schema:from_native({same, {succ, zero}, {succ, zero}}, <<"Same">>, S),
    ?assertError({lawspec, {refinement_violation, {index_guard, <<"== f0 f1">>}}},
        lawspec_beam_schema:from_native({same, zero, {succ, zero}}, <<"Same">>, S)).

payload_provenance_test() ->
    C = ctor(<<"Pair::Pair">>, pair, [{<<"fixed">>, {<<"Int32">>, []}},
        {<<"value">>, {parameter, 0}}, {<<"nested">>, {<<"List">>, [{parameter, 0}]}}]),
    S = schema([definition(<<"Pair">>, 1, [C])]),
    Predicates = [fun(V) -> V >= 0 end],
    ?assert(lawspec_beam_schema:all_payloads({ls_data, <<"Pair::Pair">>, [-1, 2, [3]]},
        <<"Pair Int32">>, Predicates, S)),
    ?assertNot(lawspec_beam_schema:all_payloads({ls_data, <<"Pair::Pair">>, [1, 2, [-3]]},
        <<"Pair Int32">>, Predicates, S)).

codec_bridge_test() ->
    S0 = schema([box()]),
    Codec = #{encode => fun({ls_data, <<"Box::Box">>, [V]}, [Child]) -> #{item => Child(V)} end,
              decode => fun(#{item := V}, [Child]) -> {ls_data, <<"Box::Box">>, [Child(V)]} end},
    S = lawspec_beam_schema:with_codecs(S0, #{<<"Box">> => Codec}),
    V = {ls_data, <<"Box::Box">>, [42]},
    ?assertEqual(#{item => 42}, lawspec_beam_schema:to_native(V, box_type(), S)),
    ?assertEqual(V, lawspec_beam_schema:from_native(#{item => 42}, box_type(), S)),
    ?assertError({lawspec, {integer_out_of_range, <<"Int8">>}},
        lawspec_beam_schema:from_native(#{item => 128}, box_type(), S)).

native_binding_shapes_preserve_contracts_test() ->
    C = (ctor(<<"Positive::Positive">>, positive, [{<<"value">>, {<<"Int32">>, []}}]))#{
        predicates => [fun(_, _, [V]) -> V > 0 end]},
    Original = schema([definition(<<"Positive">>, 0, [C])]),
    Shape = #{encode => fun([V]) -> #{amount => V} end,
        decode => fun(#{amount := V}) -> {ok, [V]}; (_) -> no_match end},
    Bound = lawspec_beam_schema:with_bindings(Original, #{<<"Positive::Positive">> => Shape}, #{}),
    Logical = {ls_data, <<"Positive::Positive">>, [7]},
    ?assertEqual(#{amount => 7}, lawspec_beam_schema:to_native(Logical, <<"Positive">>, Bound)),
    ?assertEqual({positive, 7}, lawspec_beam_schema:to_native(Logical, <<"Positive">>, Original)),
    ?assertEqual(Logical, lawspec_beam_schema:from_native(#{amount => 7}, <<"Positive">>, Bound)),
    ?assertError({lawspec, {refinement_violation, <<"Positive::Positive">>}},
        lawspec_beam_schema:from_native(#{amount => -7}, <<"Positive">>, Bound)).

native_codec_children_cross_canonical_and_bound_shapes_test() ->
    Inner = definition(<<"Inner">>, 0, [ctor(<<"Inner::Inner">>, inner,
        [{<<"value">>, {<<"Int8">>, []}}])]),
    Original = schema([box(), Inner]),
    Type = {<<"Box">>, [{<<"Inner">>, []}]},
    Hook = #{encode => fun({box, Child}, [Encode]) -> #{payload => Encode(Child)} end,
        decode => fun(#{payload := Child}, [Decode]) -> {box, Decode(Child)} end},
    S = lawspec_beam_schema:with_bindings(Original,
        #{<<"Inner::Inner">> => #{native_tag => native_inner}}, #{<<"Box">> => Hook}),
    Logical = {ls_data, <<"Box::Box">>, [{ls_data, <<"Inner::Inner">>, [7]}]},
    Native = #{payload => {native_inner, 7}},
    ?assertEqual(Native, lawspec_beam_schema:to_native(Logical, Type, S)),
    ?assertEqual(Logical, lawspec_beam_schema:from_native(Native, Type, S)),
    ?assertError({lawspec, {native_codec, <<"Box">>, decode, error,
        {lawspec, {integer_out_of_range, <<"Int8">>}}}},
        lawspec_beam_schema:from_native(#{payload => {native_inner, 128}}, Type, S)),
    Bad = Hook#{decode => fun(_, _) -> {foreign, 7} end},
    Broken = lawspec_beam_schema:with_bindings(Original, #{}, #{<<"Box">> => Bad}),
    ?assertError({lawspec, {native_codec, <<"Box">>, decode, error,
        {lawspec, invalid_native_constructor}}}, lawspec_beam_schema:from_native(Native, Type, Broken)).

native_binding_audit_test() ->
    Original = schema([box()]),
    ?assertError({lawspec, {unknown_native_constructor, <<"Missing">>}},
        lawspec_beam_schema:with_bindings(Original, #{<<"Missing">> => #{native_tag => missing}}, #{})),
    ?assertError({lawspec, {invalid_native_shape, <<"Box::Box">>}},
        lawspec_beam_schema:with_bindings(Original, #{<<"Box::Box">> => #{tag => changed}}, #{})),
    Mapped = lawspec_beam_schema:with_bindings(Original, #{<<"Box::Box">> => #{native_tag => box2}}, #{}),
    Hook = #{encode => fun(V, _) -> V end, decode => fun(V, _) -> V end},
    ?assertError({lawspec, {conflicting_native_binding, <<"Box">>}},
        lawspec_beam_schema:with_bindings(Mapped, #{}, #{<<"Box">> => Hook})).

native_constructor_positions_follow_the_compiler_test() ->
    Shape = lawspec_beam_schema:constructor_shape(fun([A, B]) -> {native_pair, B, A} end, 2),
    Encode = maps:get(encode, Shape), Decode = maps:get(decode, Shape),
    ?assertEqual({native_pair, 2, 1}, Encode([1, 2])),
    ?assertEqual({ok, [1, 2]}, Decode({native_pair, 2, 1})),
    ?assertEqual(no_match, Decode({other_pair, 2, 1})),
    ?assertEqual(no_match, Decode({native_pair, 1})),
    ?assertEqual(#{native_tag => ready}, lawspec_beam_schema:constructor_shape(fun([]) -> ready end, 0)),
    ?assertError({lawspec, invalid_constructor_shape},
        lawspec_beam_schema:constructor_shape(fun([A, _]) -> {pair, A, A} end, 2)).

handle_identity_test() ->
    S = schema([(definition(<<"Handle">>, 0, []))#{handle => true}]),
    Ref = make_ref(),
    A = lawspec_beam_schema:from_native(Ref, <<"Handle">>, S),
    B = lawspec_beam_schema:from_native(Ref, <<"Handle">>, S),
    C = lawspec_beam_schema:from_native(make_ref(), <<"Handle">>, S),
    ?assert(lawspec_beam_scalar:equal(A, B)),
    ?assertNot(lawspec_beam_scalar:equal(A, C)),
    ?assertEqual(Ref, lawspec_beam_schema:to_native(A, <<"Handle">>, S)),
    ?assertError({lawspec, no_portable_order}, lawspec_beam_scalar:compare(A, C)).

schema_audit_test() ->
    ?assertError({lawspec, duplicate_type}, schema([box(), box()])),
    ?assertError({lawspec, unbound_schema_parameter}, schema([
        definition(<<"Bad">>, 0, [ctor(<<"Bad::Bad">>, bad, [{<<"value">>, {parameter, 0}}])])])),
    ?assertError({lawspec, {unknown_type_or_arity, <<"List">>}},
        lawspec_beam_schema:check_type({<<"List">>, []}, schema([]))).
