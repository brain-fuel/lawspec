%% @doc Messages and fork/join constrain scenario histories independently of
%% real time. Causal observers may see different orders of concurrent calls.
%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(lawspec_beam_history_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

event(Command, Args, Result, Begin, End, Process, Call, Return) ->
    #{command => Command, arguments => Args, result => Result, called => Begin,
        returned => End, process => Process, call_clock => Call, return_clock => Return}.
model(Mode) -> (lawspec_beam_model_tests:counter(false))#{consistency := Mode}.
check(Model, Events, Initial, Final) ->
    lawspec_beam_model:with_context(Model, [ls_unit], fun(Context) ->
        lawspec_beam_history:consistent(Model, Context, Events, Initial, Final, unused)
    end).

messages_constrain_sequential_and_causal_views_test() ->
    A = event(0, [2], 2, 1, 2, a, #{a => 1}, #{a => 2}),
    B = event(1, [], 2, 3, 4, b, #{a => 2, b => 1}, #{a => 2, b => 2}),
    ?assert(lawspec_beam_history:happened_before(A, B)),
    lists:foreach(fun(Mode) ->
        ?assert(check(model(Mode), [A, B], 0, {some, 2})),
        ?assertNot(check(model(Mode), [A, B#{result := 0}], 0, {some, 2}))
    end, [<<"linearizable">>, <<"sequential">>, <<"causal">>]).

real_time_without_messages_does_not_order_weaker_views_test() ->
    A = event(0, [2], 2, 1, 2, a, #{a => 1}, #{a => 2}),
    B = event(1, [], 0, 3, 4, b, #{b => 1}, #{b => 2}),
    ?assertNot(lawspec_beam_history:happened_before(A, B)),
    ?assertNot(check(model(<<"linearizable">>), [B, A], 0, {some, 2})),
    ?assert(check(model(<<"sequential">>), [B, A], 0, {some, 2})),
    ?assert(check(model(<<"causal">>), [B, A], 0, {some, 2})).

message_clocks_are_transitive_through_non_calling_relays_test() ->
    A = event(0, [4], 4, 1, 2, a, #{a => 1}, #{a => 2}),
    B = event(1, [], 4, 3, 4, b, #{a => 2, relay => 3, b => 1}, #{a => 2, relay => 3, b => 2}),
    ?assert(lawspec_beam_history:happened_before(A, B)),
    ?assert(check(model(<<"causal">>), [A, B], 0, {some, 4})),
    ?assertNot(check(model(<<"causal">>), [A, B#{result := 0}], 0, none)).

causal_observers_check_their_own_results_in_their_visible_order_test() ->
    A = event(0, [1], 1, 1, 3, a, #{a => 1}, #{a => 2}),
    B = event(0, [1], 1, 2, 4, b, #{b => 1}, #{b => 2}),
    C = event(1, [], 2, 5, 6, c, #{a => 2, b => 2, c => 1}, #{a => 2, b => 2, c => 2}),
    %% Each writer sees its own increment. The observer receives from both,
    %% so it sees two increments, without imposing its order on their replies.
    ?assert(check(model(<<"causal">>), [A, B, C], 0, {some, 2})),
    ?assertNot(check(model(<<"sequential">>), [A, B, C], 0, {some, 2})),
    ?assertNot(check(model(<<"causal">>), [A, B, C#{result := 1}], 0, none)).

joining_branches_orders_later_parent_calls_test() ->
    A = event(0, [1], 1, 1, 3, a, #{a => 1}, #{a => 2}),
    B = event(0, [1], 2, 2, 4, b, #{b => 1}, #{b => 2}),
    Parent = event(1, [], 2, 5, 6, root, #{a => 2, b => 2, root => 1}, #{a => 2, b => 2, root => 2}),
    ?assert(check(model(<<"sequential">>), [Parent, B, A], 0, {some, 2})),
    ?assertNot(check(model(<<"sequential">>), [Parent#{result := 0}, B, A], 0, none)).

eventual_orders_messages_but_ignores_replies_test() ->
    A = event(0, [3], 999, 1, 2, a, #{a => 1}, #{a => 2}),
    Clear = event(2, [], ls_unit, 3, 4, b, #{a => 2, b => 1}, #{a => 2, b => 2}),
    ?assert(check(model(<<"eventual">>), [Clear, A], 0, {some, 0})),
    ?assertNot(check(model(<<"eventual">>), [Clear, A], 0, {some, 3})).

invalid_preconditions_and_invariants_reject_histories_test() ->
    M0 = model(<<"sequential">>),
    Add = (lawspec_beam_model:command(M0, 0))#{'when' := fun(_, [S]) -> S < 1 end},
    M = M0#{steps := setelement(1, maps:get(steps, M0), Add)},
    A = event(0, [1], 1, 1, 2, a, #{a => 1}, #{a => 2}),
    B = event(0, [1], 2, 3, 4, a, #{a => 3}, #{a => 4}),
    ?assertNot(check(M, [A, B], 0, {some, 2})),
    Bad = M0#{invariants := [{<<"model">>, fun(_, [S]) -> S =:= 0 end}]},
    ?assertNot(check(Bad, [A], 0, none)),
    ?assertNot(check(Bad#{consistency := <<"causal">>}, [A], 0, none)).

cyclic_dependency_metadata_cannot_pass_test() ->
    A = event(1, [], 0, 1, 3, a, #{a => 1, b => 2}, #{a => 2}),
    B = event(1, [], 0, 2, 4, b, #{a => 2, b => 1}, #{b => 2}),
    ?assertNot(check(model(<<"sequential">>), [A, B], 0, none)).

histories_are_not_limited_to_a_machine_word_test() ->
    Events = [event(0, [1], I, 2 * I - 1, 2 * I, a,
        #{a => 2 * I - 1}, #{a => 2 * I}) || I <- lists:seq(1, 70)],
    ?assert(check(model(<<"sequential">>), lists:reverse(Events), 0, {some, 70})),
    ?assertNot(check(model(<<"sequential">>), lists:reverse(Events), 0, {some, 69})).

empty_histories_still_check_final_state_and_invariants_test() ->
    ?assert(check(model(<<"linearizable">>), [], 0, {some, 0})),
    ?assertNot(check(model(<<"linearizable">>), [], 0, {some, 1})),
    Bad = (model(<<"causal">>))#{invariants := [{<<"model">>, fun(_, _) -> false end}]},
    ?assertNot(check(Bad, [], 0, none)).

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path), Cases = json:decode(Bytes),
    lists:foreach(fun(#{<<"mode">> := Mode, <<"events">> := Events, <<"initial">> := Initial,
            <<"final">> := Final, <<"consistent">> := Expected}) ->
        History = [event(I, Args, Result, Begin, End, Process, Called, Returned)
            || [I, Args, Result, Begin, End, Process, Called, Returned] <- Events],
        F = case Final of null -> none; _ -> {some, Final} end,
        ?assertEqual(Expected, check(model(Mode), History, Initial, F))
    end, Cases),
    io:format("~B BEAM scenario histories match the portable vector-clock checker.~n", [length(Cases)]).
