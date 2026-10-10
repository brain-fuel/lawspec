%% @doc Execution evidence comes from real native completions.
%% ref:DEC-never-pass-vacuously ref:DEC-tests-cite-requirements
-module(lawspec_beam_report_tests).
-include_lib("eunit/include/eunit.hrl").

selection_keeps_unit_and_declaration_order_test() ->
    Selection = <<"[{\"unit\":\"u\",\"name\":\"law_b\"},{\"unit\":\"u\",\"name\":\"law_a\"},{\"unit\":\"u\",\"name\":\"law_b\"}]">>,
    with_env("LAWSPEC_BEAM_LAWS", binary_to_list(Selection), fun() ->
        ?assertEqual([[a,b]], lawspec_beam_test_run:select_units([
            {<<"excluded">>,fun() -> error(unselected_unit_ran) end},
            {<<"u">>,fun() -> lawspec_beam_test_run:select(<<"u">>,
                [{<<"law_a">>,a},{<<"law_b">>,b},{<<"benchmark_x">>,benchmark}]) end}]))
    end).

unknown_selection_fails_test() ->
    with_env("LAWSPEC_BEAM_LAWS", "[{\"unit\":\"u\",\"name\":\"law_missing\"}]", fun() ->
        ?assertError({lawspec,{unknown_test_selection,[<<"u">>]}}, lawspec_beam_test_run:select_units([])),
        ?assertError({lawspec,{unknown_test_selection,[<<"law_missing">>]}}, lawspec_beam_test_run:select(<<"u">>,[]))
    end).

mixed_model_selection_is_exact_test() ->
    Selection = [#{unit => <<"u">>, name => Name} || Name <-
        [<<"law_same">>, <<"model_a__scenario_x_sequential">>, <<"supervision">>]],
    with_env("LAWSPEC_BEAM_LAWS", binary_to_list(iolist_to_binary(json:encode(Selection))), fun() ->
        ?assertEqual([[law, scenario, supervision]], lawspec_beam_test_run:select_units([
            {<<"excluded">>,fun() -> error(unselected_unit_ran) end},
            {<<"u">>,fun() -> lawspec_beam_test_run:select(<<"u">>,
                [{<<"law_same">>,law}, {<<"model_a__sequential">>,sequential},
                 {<<"model_a__scenario_x_sequential">>,scenario},
                 {<<"model_a_scenario_x__sequential">>,other_model},
                 {<<"supervision">>,supervision}]) end}]))
    end),
    lists:foreach(fun(Name) ->
        Missing = json:encode([#{unit => <<"u">>, name => Name}]),
        with_env("LAWSPEC_BEAM_LAWS", binary_to_list(iolist_to_binary(Missing)), fun() ->
            ?assertError({lawspec,{unknown_test_selection,[Name]}}, lawspec_beam_test_run:select(<<"u">>,[]))
        end)
    end, [<<"model_missing__sequential">>, <<"supervision">>]).

malformed_selection_fails_test() ->
    lists:foreach(fun(Text) -> with_env("LAWSPEC_BEAM_LAWS", Text, fun() ->
        ?assertException(error, _, lawspec_beam_test_run:select_units([]))
    end) end, ["[]", "[null]", "{}", "garbage", "[{\"unit\":\"u\",\"name\":\"benchmark_x\"}]"]).

unfiltered_selection_keeps_every_group_test() ->
    with_env("LAWSPEC_BEAM_LAWS", false, fun() ->
        ?assertEqual([a,b], lawspec_beam_test_run:select(<<"u">>,[{<<"law_a">>,a},{<<"benchmark_b">>,b}]))
    end).

native_completions_and_failures_test() ->
    with_report(fun(Path) ->
        Groups = [{"lawspec:u::law_pass",[{"one",fun() -> ok end} ]},
            {"lawspec:u::law_fail",[{"two",fun() -> error(native_failure) end}]},
            {"lawspec:u::model_counter__parallel",[{"model",fun() -> ok end}]},
            {"lawspec:u::model_counter__scenario_same",[{"scenario",fun() -> error(scenario_failure) end}]},
            {"lawspec:u::supervision",[{"supervision",fun() -> ok end}]}],
        Result = eunit:test(lawspec_beam_schedule:eunit(<<"u">>,false,true,Groups),
            [no_tty,{report,{lawspec_beam_report,[]}}]),
        ?assertEqual(error, Result),
        Rows = rows(Path),
        ?assertEqual(<<"start">>,maps:get(<<"event">>,hd(Rows))),
        ?assertEqual(<<"end">>,maps:get(<<"event">>,lists:last(Rows))),
        Tests = [R || R=#{<<"event">> := <<"test">>} <- Rows],
        ?assertEqual([{<<"u::law_fail">>,<<"failed">>},{<<"u::law_pass">>,<<"passed">>},
            {<<"u::model_counter__parallel">>,<<"passed">>},
            {<<"u::model_counter__scenario_same">>,<<"failed">>}, {<<"u::supervision">>,<<"passed">>}],
            lists:sort([{maps:get(<<"identity">>,R),maps:get(<<"status">>,R)} || R <- Tests])),
        ?assert(lists:all(fun(R) -> maps:get(<<"run">>,R)=:= <<"probe">> end, Rows))
    end).

empty_native_run_has_no_fictional_test_test() ->
    with_report(fun(Path) ->
        ?assertEqual(ok,eunit:test([], [no_tty,{report,{lawspec_beam_report,[]}}])),
        ?assertEqual([<<"start">>,<<"end">>],[maps:get(<<"event">>,R) || R <- rows(Path)])
    end).

with_report(Body) ->
    Path = filename:join(".artifacts/beam-cli-runtime",integer_to_list(erlang:unique_integer([positive])) ++ ".jsonl"),
    with_env("LAWSPEC_BEAM_REPORT",Path,fun() -> with_env("LAWSPEC_BEAM_RUN","probe",fun() ->
        try Body(Path) after file:delete(Path) end
    end) end).
rows(Path) -> {ok,Bytes}=file:read_file(Path), [json:decode(Line) || Line <- binary:split(Bytes,<<"\n">>,[global]),Line=/= <<>>].
with_env(Key, Value, Body) ->
    Previous=os:getenv(Key), set_env(Key,Value),
    try Body() after set_env(Key,Previous) end.
set_env(Key,false) -> os:unsetenv(Key);
set_env(Key,Value) -> os:putenv(Key,Value).
